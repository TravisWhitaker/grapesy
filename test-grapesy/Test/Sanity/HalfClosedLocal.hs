-- | Tests to go with <https://github.com/kazu-yamamoto/http2/pull/84>
module Test.Sanity.HalfClosedLocal (tests) where

import Control.Monad
import Test.Tasty
import Test.Tasty.HUnit

import Network.GRPC.Client qualified as Client
import Network.GRPC.Client.Binary qualified as Client.Binary
import Network.GRPC.Common
import Network.GRPC.Common.Binary (BinaryRpc)
import Network.GRPC.Server qualified as Server
import Network.GRPC.Server.Binary qualified as Server.Binary

import Test.Driver.ClientServer

tests :: TestTree
tests = testGroup "Test.Sanity.HalfClosedLocal" [
      testCase "simple"       test_simple
    , testCase "trailersOnly" test_trailersOnly
    ]

{-------------------------------------------------------------------------------
  Simple test (that doesn't use the trailers only case)
-------------------------------------------------------------------------------}

type Simple = BinaryRpc "HalfClosedLocal" "simple"

test_simple :: IO ()
test_simple = testClientServer $ ClientServerTest {
      config = def
    , client = simpleTestClient $ \conn ->
          Client.withRPC conn def (Proxy @Simple) $ \call -> do
            [] <- Client.recvAllOutputs call $ \_ -> error "unexpected output"
            forM_ [0 .. 99] $ \i ->
              Client.Binary.sendInput call $ StreamElem (i :: Int)
            Client.Binary.sendFinalInput call (100 :: Int)
    , server = [
          Server.mkRpcHandler (Proxy @Simple) $ \call -> do
            Server.sendTrailers call []
            streamFromClient call
        ]
    }
  where
    streamFromClient :: Server.Call Simple -> IO ()
    streamFromClient call =
        loop 0
      where
        loop :: Int -> IO ()
        loop n = do
          selem <- Server.Binary.recvInput call
          case selem of
            StreamElem (x :: Int) -> do
              if x == n
                then loop (n + 1)
                else error "unexpected input"
            FinalElem _x NoMetadata ->
              return ()
            NoMoreElems NoMetadata ->
              return ()

{-------------------------------------------------------------------------------
  Using Trailers-Only

  This should trigger the 'OutBodyNone' case in http2.
-------------------------------------------------------------------------------}

type TrailersOnly = BinaryRpc "HalfClosedLocal" "trailersOnly"

test_trailersOnly :: IO ()
test_trailersOnly = testClientServer $ ClientServerTest {
      config = def
    , client = simpleTestClient $ \conn ->
          Client.withRPC conn def (Proxy @TrailersOnly) $ \call -> do
            [] <- Client.recvAllOutputs call $ \_ -> error "unexpected output"
            forM_ [0 .. 99] $ \i ->
              Client.Binary.sendInput call $ StreamElem (i :: Int)
            Client.Binary.sendFinalInput call (100 :: Int)
    , server = [
          Server.mkRpcHandler (Proxy @TrailersOnly) $ \call -> do
            Server.sendTrailersOnly call []
            streamFromClient call
        ]
    }
  where
    streamFromClient :: Server.Call TrailersOnly -> IO ()
    streamFromClient call =
        loop 0
      where
        loop :: Int -> IO ()
        loop n = do
          selem <- Server.Binary.recvInput call
          case selem of
            StreamElem x -> do
              if x == n
                then loop (n + 1)
                else error "unexpected input"
            FinalElem _x NoMetadata ->
              return ()
            NoMoreElems NoMetadata ->
              return ()
