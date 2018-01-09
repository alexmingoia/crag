module Network.ACME.HTTPS.Internal where

import Control.Monad.Except (ExceptT, catchError, lift, throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.State (gets, modify)
import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as L
import Data.CaseInsensitive (CI, mk)
import Data.Default.Class (def)
import Data.PEM (pemContent, pemParseLBS)
import Data.Time
  ( UTCTime
  , defaultTimeLocale
  , diffUTCTime
  , getCurrentTime
  , parseTimeM
  )
import Network.HTTP.Client
  ( Manager
  , Request
  , RequestBody(RequestBodyLBS)
  , Response
  , httpLbs
  , method
  , parseRequest_
  , requestBody
  , responseBody
  , responseHeaders
  , responseStatus
  )
import Network.HTTP.Types
  ( HeaderName
  , StdMethod(GET, HEAD, POST)
  , hContentType
  , renderStdMethod
  )
import Text.Read (readMaybe)

import Network.ACME.Error
import Network.ACME.JWS
import Network.ACME.Object
import Network.ACME.Type

-- * To Be Removed
maxRetries :: Int
maxRetries = 20

-- * Operations
-- | Get all supported resources from server
acmePerformDirectory :: URL -> Manager -> ExceptT AcmeErr IO AcmeObjDirectory
acmePerformDirectory acmeReq manager =
  resBody' =<< liftIO (acmeHttpGet' acmeReq manager)

-- | Get new nonce
acmePerformNonce :: CragT AcmeJwsNonce
acmePerformNonce = do
  req <- gets (acmeObjDirectoryNewNonce . cragStateDirectory)
  h <- acmeHttpHead req
  AcmeJwsNonce <$> resHeader "Replay-Nonce" h

acmePerformFindAccountURL :: CragT URL
acmePerformFindAccountURL = do
  res <-
    acmeHttpJwsPostNewAccount
      AcmeDirectoryRequestNewAccount
      def {acmeObjStubAccountOnlyReturnExisting = Just True}
  resHeaderAsURL "Location" res

-- * Server Response
type AcmeResponse = Response L.ByteString

getHeader :: HeaderName -> AcmeResponse -> Maybe String
getHeader h r = B.unpack <$> getResponseHeader h r

getResponseMimeType :: AcmeResponse -> Maybe (CI B.ByteString)
getResponseMimeType r =
  mk . B.takeWhile (`notElem` [';', ' ']) <$> getResponseHeader hContentType r

getResponseHeader :: HeaderName -> AcmeResponse -> Maybe B.ByteString
getResponseHeader name = lookup name . responseHeaders

resHeader :: HeaderName -> AcmeResponse -> CragT String
resHeader h r = maybe (error "AcmeErrHeaderNotFound") return (getHeader h r)

resHeaderAsURL :: HeaderName -> AcmeResponse -> CragT URL
resHeaderAsURL x ys = do
  h <- resHeader x ys
  case parseURL h of
    Just u -> return u
    Nothing ->
      throwError
        AcmeErrDecodingHeader
          {acmeErrHeaderName = show x, acmeErrHeaderValue = h}

resRetryAfter :: AcmeResponse -> IO (Maybe Int)
resRetryAfter r = do
  currentTime <- getCurrentTime
  return $ do
    h <- getHeader "Retry-After" r
    case parseHttpTime h of
      Just t -> return . ceiling $ diffUTCTime t currentTime
      Nothing -> readMaybe h

-- | RFC 1123 only
parseHttpTime :: String -> Maybe UTCTime
parseHttpTime = parseTimeM True defaultTimeLocale "%a, %d %b %0Y %T GMT"

resBody :: FromJSON a => AcmeResponse -> CragT a
resBody res = lift . lift $ resBody' res

resBody' :: FromJSON a => AcmeResponse -> ExceptT AcmeErr IO a
resBody' res =
  case eitherDecode (responseBody res) of
    Right x -> return x
    Left msg ->
      throwError
        AcmeErrDecodingBody {acmeErrMessage = msg, acmeErrBody = show res}

parsePEMBody :: AcmeResponse -> [B.ByteString]
parsePEMBody res =
  case pemParseLBS (responseBody res) of
    Left e -> error e --ErrDecodingPEM e
    Right v -> map pemContent v

-- * State Operations
acmeTAddNonce :: AcmeResponse -> CragT ()
acmeTAddNonce r = acmeTSetNonce $ AcmeJwsNonce <$> getHeader "Replay-Nonce" r

acmeTSetNonce :: Maybe AcmeJwsNonce -> CragT ()
acmeTSetNonce n = modify (\s -> s {cragStateNonce = n})

acmeTSetKid :: Maybe URL -> CragT ()
acmeTSetKid k = modify (\s -> s {cragStateKid = k})

acmeTGetNonce :: CragT AcmeJwsNonce
acmeTGetNonce = do
  nonce <- gets cragStateNonce
  case nonce of
    Just x -> return x
    Nothing -> acmePerformNonce

acmeDictionaryUrl :: AcmeDirectoryRequest -> CragT URL
acmeDictionaryUrl req = do
  url <- gets (acmeRequestUrl req . cragStateDirectory)
  maybe (throwError $ AcmeErrRequestNotSupported req) return url

-- * Perform HTTPS
acmeHttpJwsPostNewAccount ::
     (ToJSON a) => AcmeDirectoryRequest -> a -> CragT AcmeResponse
acmeHttpJwsPostNewAccount r x = do
  url <- acmeDictionaryUrl r
  acmeHttpJwsPost' 0 False url x

acmeHttpJwsPostUrl :: (ToJSON a) => URL -> a -> CragT AcmeResponse
acmeHttpJwsPostUrl = acmeHttpJwsPost' 0 True

acmeHttpJwsPost :: (ToJSON a) => AcmeDirectoryRequest -> a -> CragT AcmeResponse
acmeHttpJwsPost r x = do
  url <- acmeDictionaryUrl r
  acmeHttpJwsPostUrl url x

acmeHttpJwsPost' :: (ToJSON a) => Int -> Bool -> URL -> a -> CragT AcmeResponse
acmeHttpJwsPost' retried withKid url bod = do
  vKid <- accURL
  acmeTSetKid vKid
  nonce <- acmeTGetNonce
  vJwkPublic <- asks (cragSetupJwkPublic . cragSetup)
  vJwkPrivate <- asks (cragConfigJwk . cragConfig)
  req <- lift . lift $ acmeNewJwsBody bod url vJwkPrivate vJwkPublic nonce vKid
  res <- catchError (acmeHttpPost url req) handler
  acmeTAddNonce res
  return res
  where
    handler :: AcmeErr -> CragT AcmeResponse
    handler e@AcmeErrDetail {}
      | errBadNonce e || retried >= maxRetries = do
        acmeTSetNonce Nothing
        acmeHttpJwsPost' (retried + 1) withKid url bod
      | otherwise = throwError e
    handler e = throwError e
    accURL :: CragT (Maybe URL)
    accURL
      | withKid = Just <$> acmePerformFindAccountURL
      | otherwise = return Nothing

-- ** Lower level
-- | Perform POST query
acmeHttpPost :: URL -> AcmeJws -> CragT AcmeResponse
acmeHttpPost req bod = do
  cragLog $ "POST " ++ show req
  manager <- asks (cragSetupHttpManager . cragSetup)
  parseResult req (Just bod') $
    httpLbs
      (newHttpRequest POST req) {requestBody = RequestBodyLBS bod'}
      manager
  where
    bod' = encode bod

-- | Perform GET query
acmeHttpGet ::
     URL -- ^ Request
  -> CragT AcmeResponse
acmeHttpGet req = do
  cragLog $ "GET " ++ show req
  manager <- asks (cragSetupHttpManager . cragSetup)
  liftIO $ acmeHttpGet' req manager

acmeHttpGet' ::
     URL -- ^ Request
  -> Manager
  -> IO AcmeResponse
acmeHttpGet' req
  --parseResult req Nothing $ 
 = httpLbs (newHttpRequest GET req)

-- | Perform HEAD query
acmeHttpHead ::
     URL -- ^ Request
  -> CragT AcmeResponse
acmeHttpHead req = do
  cragLog $ "HEAD " ++ show req
  manager <- asks (cragSetupHttpManager . cragSetup)
  parseResult req Nothing $ httpLbs (newHttpRequest HEAD req) manager

-- | Transforms abstract ACME to concrete HTTP request
newHttpRequest :: StdMethod -> URL -> Request
newHttpRequest meth acmeReq =
  (parseRequest_ url) {method = renderStdMethod meth}
  where
    url = urlToString acmeReq

-- ** Utils
parseResult ::
     URL
  -> Maybe L.ByteString -- ^ Body
  -> IO (Response L.ByteString)
  -> CragT AcmeResponse
parseResult req bod resIO = do
  res <- liftIO resIO
  if getResponseMimeType res /= Just "application/problem+json"
    then return res
    else case eitherDecode (responseBody res) of
           Right e ->
             throwError
               AcmeErrDetail
                 { acmeErrRequest = req
                 , acmeErrHttpStatus = responseStatus res
                 , acmeErrProblemDetail = e
                 , acmeErrRequestBody = bod
                 }
           Left msg ->
             throwError
               AcmeErrDecodingProblemDetail
                 { acmeErrHttpStatus = responseStatus res
                 , acmeErrMessage = msg
                 , acmeErrResponseBody = L.unpack $ responseBody res
                 }
