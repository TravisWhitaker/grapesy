{-# LANGUAGE OverloadedStrings #-}

-- | Dealing with invalid headers
--
-- This is its own module primarily to avoid cyclic dependencies.
module Network.GRPC.Spec.Headers.Invalid (
    InvalidHeaders(..)
  , InvalidHeader(..)
    -- * Construction
  , invalidHeader
  , invalidHeaderWith
  , missingHeader
  , unexpectedHeader
  , throwInvalidHeader
    -- * Utility
  , prettyInvalidHeaders
  , statusInvalidHeaders
  ) where

import Control.Monad.Except
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Builder qualified as ByteString (Builder)
import Data.ByteString.UTF8 qualified as BS.UTF8
import Data.CaseInsensitive qualified as CI
import Data.Foldable (asum)
import Data.Maybe (fromMaybe)
import Network.HTTP.Types qualified as HTTP

{-------------------------------------------------------------------------------
  Definition
-------------------------------------------------------------------------------}

-- | Invalid headers
--
-- This is used for request headers, response headers, and response trailers.
newtype InvalidHeaders = InvalidHeaders {
      getInvalidHeaders :: [InvalidHeader]
    }
  deriving stock (Show, Eq)
  deriving newtype (Semigroup, Monoid)

-- | Invalid header
--
-- This corresponds to a single \"raw\" HTTP header. It is possible that a
-- particular field of, say, 'Network.GRPC.Spec.Headers.Request.RequestHeaders'
-- corresponds to /multiple/ 'InvalidHeader', when the value of that field is
-- determined by combining multiple HTTP headers. A special case of this is the
-- field for unrecognized headers (see
-- 'Network.GRPC.Spec.Headers.Request.requestUnrecognized',
-- 'Network.GRPC.Spec.Headers.Response.responseUnrecognized', etc.), which
-- collects /all/ unrecognized headers in one field (and has value @()@ if there
-- are none).
data InvalidHeader =
    -- | We failed to parse this header
    --
    -- We record the original header and the reason parsing failed.
    --
    -- For some invalid headers the gRPC spec mandates a specific HTTP status;
    -- if this status is not specified, then we use 400 Bad Request.
    InvalidHeader (Maybe HTTP.Status) HTTP.Header String

    -- | Missing header (header that should have been present but was not)
  | MissingHeader HTTP.HeaderName

    -- | Unexpected header (header that should not have been present but was)
  | UnexpectedHeader HTTP.HeaderName
  deriving stock (Show, Eq)

{-------------------------------------------------------------------------------
  Construction
-------------------------------------------------------------------------------}

invalidHeader :: HTTP.Header -> String -> InvalidHeaders
invalidHeader hdr err = wrapOne $ InvalidHeader Nothing hdr err

invalidHeaderWith :: HTTP.Status -> HTTP.Header -> String -> InvalidHeaders
invalidHeaderWith status hdr err = wrapOne $ InvalidHeader (Just status) hdr err

missingHeader :: HTTP.HeaderName -> InvalidHeaders
missingHeader name = wrapOne $ MissingHeader name

unexpectedHeader :: HTTP.HeaderName -> InvalidHeaders
unexpectedHeader name = wrapOne $ UnexpectedHeader name

throwInvalidHeader ::
     MonadError InvalidHeaders m
  => HTTP.Header
  -> Either String a
  -> m a
throwInvalidHeader _   (Right a)  = return a
throwInvalidHeader hdr (Left err) = throwError $ invalidHeader hdr err

{-------------------------------------------------------------------------------
  Utility
-------------------------------------------------------------------------------}

prettyInvalidHeaders :: InvalidHeaders -> ByteString.Builder
prettyInvalidHeaders = mconcat . map go . getInvalidHeaders
  where
    go :: InvalidHeader -> ByteString.Builder
    go (InvalidHeader _status (name, value) err) = mconcat [
          "Invalid header '"
        , Builder.byteString (CI.original name)
        , "' with value '"
        , Builder.byteString value
        , "': "
        , Builder.byteString $ BS.UTF8.fromString err
        , "\n"
        ]
    go (MissingHeader name) = mconcat [
          "Missing header '"
        , Builder.byteString (CI.original name)
        , "'\n"
        ]
    go (UnexpectedHeader name) = mconcat [
          "Unexpected header '"
        , Builder.byteString (CI.original name)
        , "'\n"
        ]

-- | HTTP status to report
--
-- If there are multiple headers, each of which with a mandated status, we
-- just use the first; the spec is essentially ambiguous in this case.
statusInvalidHeaders :: InvalidHeaders -> HTTP.Status
statusInvalidHeaders (InvalidHeaders hs) =
    fromMaybe HTTP.badRequest400 $ asum $ map getStatus hs
  where
    getStatus :: InvalidHeader -> Maybe HTTP.Status
    getStatus (InvalidHeader status _ _) = status
    getStatus MissingHeader{}            = Nothing
    getStatus UnexpectedHeader{}         = Nothing

{-------------------------------------------------------------------------------
  Internal auxiliary
-------------------------------------------------------------------------------}

wrapOne :: InvalidHeader -> InvalidHeaders
wrapOne = InvalidHeaders . (:[])

