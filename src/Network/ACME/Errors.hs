module Network.ACME.Errors where

import Control.Monad.Trans.Except
import Crypto.JOSE
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as L
import Data.Maybe
import Data.Yaml.Pretty
import Network.HTTP.Types

import Network.ACME.Types

handleError :: ExceptT RequestError IO a -> IO a
handleError x = do
  res <- runExceptT x
  case res of
    Left e -> error $ "fatal:\n" ++ showRequestError e
    Right y -> return y

maybeToExceptT :: RequestError -> Maybe a -> ExceptT RequestError IO a
maybeToExceptT e Nothing = throwE e
maybeToExceptT _ (Just x) = return x

data RequestError
  = RequestErrorDetail String
                       Status
                       ProblemDetail
                       (Maybe L.ByteString)
  | DecodingError String
                  String
  | ErrorDecodingError Status
                       String
                       String
  | RequestErrorStatus Status
  | RequestJwsError Error
  | RequestNotSupported String
  | AcmeErrNoToken AcmeObjChallenge
  | AcmeErrNoChallenge String
  deriving (Show)

showRequestError :: RequestError -> String
showRequestError (RequestErrorDetail r s d b) =
  "Request: " ++
  r ++
  "\nStatus: " ++
  showStatus s ++
  "\n\nDetails:\n" ++
  B.unpack (encodePretty defConfig d) ++
  "\nRequest Body:\n" ++ L.unpack (fromMaybe "EMPTY" b)
showRequestError (DecodingError msg original) =
  "The stuff could not be decoded:\n" ++ msg ++ "\n\n" ++ original
showRequestError x = show x

showStatus :: Status -> String
showStatus Status {..} = show statusCode ++ " " ++ B.unpack statusMessage