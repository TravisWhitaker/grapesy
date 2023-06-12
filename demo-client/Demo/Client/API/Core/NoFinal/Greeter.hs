module Demo.Client.API.Core.NoFinal.Greeter (
    sayHello
  ) where

import Control.Concurrent.STM
import Data.Default

import Network.GRPC.Client
import Network.GRPC.Client.Protobuf (RPC(..))

import Proto.Helloworld

{-------------------------------------------------------------------------------
  helloworld.Greeter
-------------------------------------------------------------------------------}

sayHello :: Connection -> HelloRequest -> IO ()
sayHello conn n =
    withRPC conn def (RPC @Greeter @"sayHello") $ \call -> do
      atomically $ sendInput call $ StreamElem n
      out      <- atomically $ recvOutput call
      trailers <- atomically $ recvOutput call
      print (out, trailers)