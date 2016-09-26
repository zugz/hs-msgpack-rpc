{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Network.MessagePack.Client.Internal where

import           Control.Applicative               (Applicative)
import           Control.Monad                     (when)
import           Control.Monad.Catch               (MonadCatch, MonadThrow,
                                                    throwM)
import qualified Control.Monad.State.Strict        as CMS
import qualified Data.Binary                       as Binary
import qualified Data.ByteString                   as S
import           Data.Conduit                      (ResumableSource, Sink, ($$),
                                                    ($$++))
import qualified Data.Conduit.Binary               as CB
import           Data.Conduit.Serialization.Binary (sinkGet)
import           Data.MessagePack                  (Object, fromObject)

import           Network.MessagePack.Types


-- | RPC connection type
data Connection m = Connection
  { connSource :: ResumableSource m S.ByteString
  , connSink   :: Sink S.ByteString m ()
  , connMsgId  :: Int
  , connMths   :: [String]
  }


newtype ClientT m a
  = ClientT { runClientT :: CMS.StateT (Connection m) m a }
  deriving (Functor, Applicative, Monad, CMS.MonadIO, MonadThrow, MonadCatch)

type Client a = ClientT IO a


rpcCall :: (MonadThrow m, CMS.MonadIO m) => String -> [Object] -> ClientT m Object
rpcCall methodName args = ClientT $ do
  conn <- CMS.get
  let msgid = connMsgId conn

  (rsrc', res) <- CMS.lift $ do
    let req = packRequest (connMths conn) (0, msgid, methodName, args)
    CB.sourceLbs req $$ connSink conn
    connSource conn $$++ sinkGet Binary.get

  CMS.put conn
    { connSource = rsrc'
    , connMsgId  = msgid + 1
    }

  case unpackResponse res of
    Nothing -> throwM $ ProtocolError "invalid response data"
    Just (rtype, rmsgid, rerror, rresult) -> do
      when (rtype /= 1) $
        throwM $ ProtocolError $
          "invalid response type (expect 1, but got " ++ show rtype ++ "): " ++ show res

      when (rmsgid /= msgid) $
        throwM $ ProtocolError $
          "message id mismatch: expect " ++ show msgid ++ ", but got " ++ show rmsgid

      case fromObject rerror of
        Nothing -> throwM $ RemoteError rerror
        Just () -> return rresult


setMethodList :: Monad m => [String] -> ClientT m ()
setMethodList mths = ClientT $ do
  conn <- CMS.get
  CMS.put conn { connMths = mths }