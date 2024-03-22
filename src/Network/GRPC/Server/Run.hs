-- | Convenience functions for running a HTTP2 server
--
-- Intended for unqualified import.
module Network.GRPC.Server.Run (
    -- * Configuration
    ServerConfig(..)
  , InsecureConfig(..)
  , SecureConfig(..)
    -- * Simple interface
  , runServer
  , runServerWithHandlers
    -- * Full interface
  , RunningServer -- opaque
  , forkServer
  , waitServer
  , waitServerSTM
  , getInsecureSocket
  , getSecureSocket
  , getServerSocket
  , getServerPort
    -- * Exceptions
  , ServerTerminated(..)
  , CouldNotLoadCredentials(..)
  ) where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Network.ByteOrder (BufferSize)
import Network.HTTP2.Server qualified as HTTP2
import Network.HTTP2.TLS.Server qualified as HTTP2.TLS
import Network.Run.TCP qualified as Run
import Network.Socket
import Network.TLS qualified as TLS

import Network.GRPC.Server (mkGrpcServer, ServerParams, RpcHandler)
import Network.GRPC.Util.TLS (SslKeyLog(..))
import Network.GRPC.Util.TLS qualified as Util.TLS

{-------------------------------------------------------------------------------
  Configuration
-------------------------------------------------------------------------------}

-- | Server configuration
--
-- Describes the configuration of both an insecure server and a secure server.
-- See the documentation of 'runServer' for a description of what servers will
-- result from various configurations.
data ServerConfig = ServerConfig {
      -- | Configuration for insecure communication (without TLS)
      --
      -- Set to 'Nothing' to disable.
      serverInsecure :: Maybe InsecureConfig

      -- | Configuration for secure communication (over TLS)
      --
      -- Set to 'Nothing' to disable.
    , serverSecure :: Maybe SecureConfig
    }

-- | Offer insecure connection (no TLS)
data InsecureConfig = InsecureConfig {
      -- | Hostname
      insecureHost :: Maybe HostName

      -- | Port number
      --
      -- Can use @0@ to let the server pick its own port. This can be useful in
      -- testing scenarios; see 'getServerPort' or the more general
      -- 'getInsecureSocket' for a way to figure out what this port actually is.
    , insecurePort :: PortNumber
    }
  deriving (Show)

-- | Offer secure connection (over TLS)
data SecureConfig = SecureConfig {
      -- | Hostname to bind to
      --
      -- Unlike in 'InsecureConfig', the 'HostName' is required here, because it
      -- must match the certificate.
      --
      -- This doesn't need to match the common name (CN) in the TLS certificate.
      -- For example, if the client connects to @localhost@, and the certificate
      -- CN is also @localhost@, the server can still bind to @0.0.0.0@.
      secureHost :: HostName

      -- | Port number
      --
      -- See 'insecurePort' for additional discussion'.
    , securePort :: PortNumber

      -- | TLS public certificate (X.509 format)
    , securePubCert :: FilePath

      -- | TLS chain certificates (X.509 format)
    , secureChainCerts :: [FilePath]

      -- | TLS private key
    , securePrivKey :: FilePath

      -- | SSL key log
    , secureSslKeyLog :: SslKeyLog
    }
  deriving (Show)

{-------------------------------------------------------------------------------
  Simple interface
-------------------------------------------------------------------------------}

-- | Run a 'HTTP2.Server' with the given 'ServerConfig'.
--
-- If both configurations are disabled, 'runServer' will simply immediately
-- return. If both configurations are enabled, then two servers will be run
-- concurrently; one with the insecure configuration and the other with the
-- secure configuration. Obviously, if only one of the configurations is
-- enabled, then just that server will be run.
--
-- See also 'runServerWithHandlers', which handles the creation of the
-- 'HTTP2.Server' for you.
runServer :: ServerConfig -> HTTP2.Server -> IO ()
runServer cfg server = forkServer cfg server $ waitServer

-- | Convenience function that combines 'runServer' with 'mkGrpcServer'
runServerWithHandlers ::
     ServerConfig
  -> ServerParams
  -> [RpcHandler IO]
  -> IO ()
runServerWithHandlers config params handlers = do
    server <- mkGrpcServer params handlers
    runServer config server

{-------------------------------------------------------------------------------
  Full interface
-------------------------------------------------------------------------------}

data RunningServer = RunningServer {
      -- | Insecure server (no TLS)
      --
      -- If the insecure server is disabled, this will be a trivial "Async' that
      -- immediately completes.
      runningServerInsecure :: Async ()

      -- | Secure server (with TLS)
      --
      -- Similar remarks apply as for 'runningInsecure'.
    , runningServerSecure :: Async ()

      -- | Socket used by the insecure server
      --
      -- See 'getInsecureSocket'.
    , runningSocketInsecure :: TMVar Socket

      -- | Socket used by the secure server
      --
      -- See 'getSecureSocket'.
    , runningSocketSecure :: TMVar Socket
    }

data ServerTerminated = ServerTerminated
  deriving stock (Show)
  deriving anyclass (Exception)

-- | Start the server
forkServer :: ServerConfig -> HTTP2.Server -> (RunningServer -> IO a) -> IO a
forkServer ServerConfig{serverInsecure, serverSecure} server k = do
    runningSocketInsecure <- newEmptyTMVarIO
    runningSocketSecure   <- newEmptyTMVarIO

    let secure, insecure :: IO ()
        insecure = case serverInsecure of
                     Nothing  -> return ()
                     Just cfg -> runInsecure cfg runningSocketInsecure server
        secure   = case serverSecure of
                     Nothing  -> return ()
                     Just cfg -> runSecure cfg runningSocketSecure server

    withAsync insecure $ \runningServerInsecure ->
      withAsync secure $ \runningServerSecure ->
        k RunningServer{
              runningServerInsecure
            , runningServerSecure
            , runningSocketInsecure
            , runningSocketSecure
            }

-- | Wait for the server to terminate
--
-- Returns the results of the insecure and secure servers separately.
-- Note that under normal circumstances the server /never/ terminates.
waitServerSTM ::
     RunningServer
  -> STM ( Either SomeException ()
         , Either SomeException ()
         )
waitServerSTM server = do
    insecure <- waitCatchSTM (runningServerInsecure server)
    secure   <- waitCatchSTM (runningServerSecure   server)
    return (insecure, secure)

-- | IO version of 'waitServerSTM' that rethrows exceptions
waitServer :: RunningServer -> IO ()
waitServer server =
    atomically (waitServerSTM server) >>= \case
      (Right (), Right ()) -> return ()
      (Left  e , _       ) -> throwIO e
      (_       , Left  e ) -> throwIO e

-- | Get the socket used by the insecure server
--
-- The socket is created as the server initializes; this function will block
-- until that is complete. However:
--
-- * If the server throws an exception, that exception is rethrown here.
-- * If the server has already terminated, we throw 'ServerTerminated'
-- * If the insecure server was not enabled, it is considered to have terminated
--   immediately and the same 'ServerTerminated' exception is thrown.
getInsecureSocket :: RunningServer -> STM Socket
getInsecureSocket server = do
    getSocket (runningServerInsecure server)
              (runningSocketInsecure server)

-- | Get the socket used by the secure server
--
-- Similar remarks apply as for 'getInsecureSocket'.
getSecureSocket :: RunningServer -> STM Socket
getSecureSocket server = do
    getSocket (runningServerSecure server)
              (runningSocketSecure server)

-- | Get \"the\" socket associated with the server
--
-- Precondition: only one server must be enabled (secure or insecure).
getServerSocket :: RunningServer -> STM Socket
getServerSocket server = do
    insecure <- catchSTM (Right <$> getInsecureSocket server) (return . Left)
    secure   <- catchSTM (Right <$> getSecureSocket   server) (return . Left)
    case (insecure, secure) of
      (Right sock, Left ServerTerminated) ->
        return sock
      (Left ServerTerminated, Right sock) ->
        return sock
      (Left ServerTerminated, Left ServerTerminated) ->
        throwSTM ServerTerminated
      (Right _, Right _) ->
        error $ "getServerSocket: precondition violated"

-- | Get \"the\" port number used by the server
--
-- Precondition: only one server must be enabled (secure or insecure).
getServerPort :: RunningServer -> IO PortNumber
getServerPort server = do
    sock <- atomically $ getServerSocket server
    addr <- getSocketName sock
    case addr of
      SockAddrInet  port   _host   -> return port
      SockAddrInet6 port _ _host _ -> return port
      SockAddrUnix{} -> error "getServerPort: unexpected unix socket"

-- | Internal generalization of 'getInsecureSocket'/'getSecureSocket'
getSocket :: Async () -> TMVar Socket -> STM Socket
getSocket serverAsync socketTMVar = do
    status <-  (Left  <$> waitCatchSTM serverAsync)
      `orElse` (Right <$> readTMVar    socketTMVar)
    case status of
      Left (Left err) -> throwSTM err
      Left (Right ()) -> throwSTM $ ServerTerminated
      Right sock      -> return sock

{-------------------------------------------------------------------------------
  Insecure
-------------------------------------------------------------------------------}

runInsecure :: InsecureConfig -> TMVar Socket -> HTTP2.Server -> IO ()
runInsecure cfg socketTMVar server =
    Run.runTCPServerWithSocket
        (openServerSocket socketTMVar)
        (insecureHost cfg)
        (show $ insecurePort cfg) $ \sock -> do
      bracket (HTTP2.allocSimpleConfig sock writeBufferSize)
              HTTP2.freeSimpleConfig $ \config ->
        HTTP2.run HTTP2.defaultServerConfig config server

{-------------------------------------------------------------------------------
  Secure (over TLS)
-------------------------------------------------------------------------------}

runSecure :: SecureConfig -> TMVar Socket -> HTTP2.Server -> IO ()
runSecure cfg socketTMVar server = do
    cred :: TLS.Credential <-
          TLS.credentialLoadX509Chain
            (securePubCert    cfg)
            (secureChainCerts cfg)
            (securePrivKey    cfg)
      >>= \case
            Left  err -> throwIO $ CouldNotLoadCredentials err
            Right res -> return res

    keyLogger <- Util.TLS.keyLogger (secureSslKeyLog cfg)
    let settings :: HTTP2.TLS.Settings
        settings = HTTP2.TLS.defaultSettings {
              HTTP2.TLS.settingsKeyLogger =
                keyLogger
            , HTTP2.TLS.settingsOpenServerSocket =
                openServerSocket socketTMVar
            }

    HTTP2.TLS.run
      settings
      (TLS.Credentials [cred])
      (secureHost cfg)
      (securePort cfg)
      server

data CouldNotLoadCredentials =
    -- | Failed to load server credentials
    CouldNotLoadCredentials String
  deriving stock (Show)
  deriving anyclass (Exception)

{-------------------------------------------------------------------------------
  Internal auxiliary
-------------------------------------------------------------------------------}

openServerSocket :: TMVar Socket -> AddrInfo -> IO Socket
openServerSocket socketTMVar addr = do
    sock <- Run.openServerSocket addr
    atomically $ putTMVar socketTMVar sock
    return sock

writeBufferSize :: BufferSize
writeBufferSize = 4096
