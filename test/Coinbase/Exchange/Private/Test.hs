{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

module Coinbase.Exchange.Private.Test
    ( tests
    , giveAwayOrder
    , run_placeOrder
    ) where

import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Concurrent

import           Data.IORef
import           Data.Maybe
import           Data.List
import           Data.Time
import           Data.Scientific
import           Data.UUID

import           System.Random

import           Test.Tasty
import           Test.Tasty.HUnit

import           Coinbase.Exchange.Private
import           Coinbase.Exchange.Types
import           Coinbase.Exchange.Types.Core
import           Coinbase.Exchange.Types.Private

import           Network.HTTP.Client.TLS
import           Network.HTTP.Conduit
import           System.Environment
import qualified Data.ByteString.Char8             as CBS

deriving instance Eq Order


tests :: ExchangeConf -> TestTree
tests conf = testGroup "Private"
        [ testCase "getAccountList"     (do as <- run_getAccountList conf
                                            case as of
                                                [] -> error "Received empty list of accounts"
                                                _  -> return ()
                                        )

        , testCase "getUSDAccount"      (do as <- run_getAccountList conf
                                            let usdAccount = findUSDAccount as
                                            ac <- run_getAccount conf (accId usdAccount)
                                            assertEqual "accounts match" usdAccount ac
                                        )

        , testCase "getUSDAccountLedger" ( do as <- run_getAccountList conf
                                              let usdAccount = findUSDAccount as
                                              es <- run_getAccountLedger conf (accId usdAccount)
                                              case es of
                                                  [] -> assertFailure "Received empty list of ledger entries" -- must not be empty to test parser
                                                  _  -> return ()
                                         )

        , testCase "placeOrder"         (do o   <- creatNewLimitOrder
                                            oid <- run_placeOrder conf o             -- limit order
                                            oid'<- run_placeOrder conf giveAwayOrder -- market order
                                            return ()
                                        )

        , testCase "getOrderList"       (do run_getOrderList conf [Open, Pending] -- making sure this request is well formed
                                            os <- run_getOrderList conf []
                                            case os of
                                                [] -> assertFailure "Received empty order list"
                                                _  -> return ()
                                        )

        , testCase "getOrder"           (do no  <- creatNewLimitOrder
                                            oid <- run_placeOrder conf no
                                            threadDelay 1000000 -- 1 second delay
                                            o   <- run_getOrder conf oid
                                            assertEqual "order price"    (noPrice no) (orderPrice o)
                                            assertEqual "order size"     (noSize  no) (orderSize  o)
                                            assertEqual "order side"     (noSide  no) (orderSide  o)
                                            assertEqual "order product"  (noProductId no) (orderProductId o)
                                        )
        , testCase "cancelOrder"        (do no  <- creatNewLimitOrder
                                            threadDelay 4000000 -- 4 second delay, to run after other tests
                                            oid <- run_placeOrder  conf no
                                            threadDelay 1000000 -- 1 second delay
                                            os  <- run_getOrderList conf [Open, Pending]
                                            threadDelay 1000000 -- 1 second delay
                                            run_cancelOrder conf oid
                                            threadDelay 1000000 -- 1 second delay
                                            os' <- run_getOrderList conf [Open, Pending]
                                            case os \\ os' of
                                                            [o] -> do
                                                                    assertEqual "order price"    (noPrice no) (orderPrice o)
                                                                    assertEqual "order size"     (noSize  no) (orderSize  o)
                                                                    assertEqual "order side"     (noSide  no) (orderSide  o)
                                                                    assertEqual "order product"  (noProductId no) (orderProductId o)

                                                            [] -> assertFailure "order not canceled"
                                                            _  -> assertFailure "more than one order canceled"
                                        )

        , testCase "getFills" (do oid <- run_placeOrder conf giveAwayOrder
                                  threadDelay 1000000 -- 1 second delay
                                  fs <- run_getFills conf (Just oid) Nothing
                                  case fs of
                                    [] -> assertFailure "No fills found for an order that should execute immediately"
                                    _  -> return ()
                              )


        -------------------------- BTC TRANSFER TESTS --------------------------
        -- CAREFULL ON LIVE ENVIRONMENT!!! TRANSFERS ARE IRREVERSIBLE!!!

        -- This test cause a "403 Forbiden" error when run in the Sanbox. I'm not sure that can be fixed on my end.
        , testCase "Withdraw BTCs" $
            assertFailure "BTC withdrawal test Suspended for Safety"
            -- (do
            -- res <- run_withdrawBTC conf sampleTransfer
            -- print res
            -- return ()
            -- )

        --------------------------------------------------------------------------------
        ]

-----------------------------------------------
-- DO NOT USE!! CAREFUL!! THIS WILL TRY TO SEND YOUR BITCOINS TO THE SPECIFIED WALLET BELOW!
-- THIS MAY BE IRREVERSIBLE.
sampleTransfer :: CryptoWithdrawal
sampleTransfer = Withdrawal
        { wdAmount        = 0.02
        , wdCurrency      = CurrencyId "BTC"
        , wdCryptoAddress = BTCWallet (FromBTCAddress "INVALID-WALLET-INVALID-WALLET-INVA")
        }

giveAwayOrder :: NewOrder
giveAwayOrder = NewMarketOrder
    -- CAREFUL CHANGING THESE VALUES IF YOU PERFORM TESTING IN THE LIVE ENVIRONMENT. YOU MAY LOSE MONEY.
    { noProductId = "BTC-USD"
    , noSide      = Sell
    , noSelfTrade = DecrementAndCancel
    , noClientOid = Just $ ClientOrderId $ fromJust $ fromString "c2cc10e1-57d6-4b6f-9899-deadbeef2d8c"
    , noSizeAndOrFunds = Right (Just 0.01, 5) -- at most 1 BTC cent or 5 dollars per test
    }

creatNewLimitOrder :: IO NewOrder
creatNewLimitOrder = do
    -- can't be deterministic because exchange is stateful
    -- running a test twice with same random input may produce different results
    sz <- randomRIO (0,9999)
    -- CAREFUL CHANGING THESE VALUES IF YOU PERFORM TESTING IN THE LIVE ENVIRONMENT. YOU MAY LOOSE MONEY.
    return NewLimitOrder
        { noSize      = 0.01 + Size (CoinScientific $ fromInteger sz / 1000000 )
        , noPrice     = 10.36
        , noProductId = "BTC-USD"
        , noSide      = Buy
        , noSelfTrade = DecrementAndCancel
        , noClientOid = Just $ ClientOrderId $ fromJust $ fromString "c2cc10e1-57d6-4b6f-9899-111122223d8c"
        , noPostOnly  = False
        , noTimeInForce = GoodTillCanceled
        , noCancelAfter = Nothing
        }


findUSDAccount :: [Account] -> Account
findUSDAccount as = case filter (\a -> accCurrency a == CurrencyId "USD") as of
                        [a] -> a
                        []  -> error "no USD denominated account found"
                        _   -> error "more than one account denominated in USD found"

-----------------------------------------------
onSuccess :: ExchangeConf -> Exchange a -> String -> IO a
onSuccess conf apicall errorstring = do
        r <- liftIO $ runExchange conf apicall
        case r of
            Left  e -> print e >> error errorstring
            Right a -> return a

run_getAccountList :: ExchangeConf -> IO [Account]
run_getAccountList conf = onSuccess conf getAccountList "Failed to get account list"

run_getAccount :: ExchangeConf -> AccountId -> IO Account
run_getAccount conf acID = onSuccess conf (getAccount acID) "Failed to get account info"

run_getAccountLedger :: ExchangeConf -> AccountId -> IO [Entry]
run_getAccountLedger conf acID = onSuccess conf (getAccountLedger acID) "Failed to get account ledger"

run_placeOrder :: ExchangeConf -> NewOrder -> IO OrderId
run_placeOrder conf o = onSuccess conf (createOrder o) "Failed to create order"

run_getOrder :: ExchangeConf -> OrderId -> IO Order
run_getOrder conf oid = onSuccess conf (getOrder oid) "Failed to get order info"

run_getOrderList :: ExchangeConf -> [OrderStatus] -> IO [Order]
run_getOrderList conf ss = onSuccess conf (getOrderList ss) "Failed to get order list"

run_cancelOrder :: ExchangeConf -> OrderId -> IO ()
run_cancelOrder conf oid = onSuccess conf (cancelOrder oid) "Failed to cancel order"

run_getFills :: ExchangeConf -> Maybe OrderId -> Maybe ProductId -> IO [Fill]
run_getFills conf moid mpid = onSuccess conf (getFills moid mpid) "Failed to get fills"

run_withdrawBTC :: ExchangeConf -> CryptoWithdrawal -> IO CryptoWithdrawalResp
run_withdrawBTC conf w = onSuccess conf (createCryptoWithdrawal w) "Failed to create withdrawal"
