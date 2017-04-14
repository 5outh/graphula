{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Graphula
  ( node
  , nodeEdit
  , nodeWith
  , nodeEditWith
  , HasDependencies(..)
  , Graph
  , runGraphula
  , runGraphulaReplay
  , Frontend(..)
  , NoConstraint
  , Only(..)
  , only
  ) where

import Prelude hiding (readFile, lines)
import Test.QuickCheck (Arbitrary(..), generate)
import Test.HUnit.Lang (HUnitFailure(..), FailureReason(..), formatFailureReason)
import Control.Monad.Catch (MonadCatch(..), MonadThrow(..))
import Control.Monad.Trans.Free (FreeT, iterT, liftF, transFreeT)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Exception (Exception, bracket)
import Data.Semigroup ((<>))
import Data.Aeson (ToJSON, FromJSON, encode, eitherDecode)
import Data.ByteString (ByteString, hPutStr, readFile)
import Data.ByteString.Char8 (lines)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.Functor.Sum (Sum(..))
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef')
import Data.Proxy (Proxy(..))
import Data.Typeable (Typeable, TypeRep, typeRep)
import Generics.Eot (Void, fromEot, toEot, Eot, HasEot)
import GHC.Exts (Constraint)
import GHC.Generics (Generic)
import GHC.TypeLits (TypeError, ErrorMessage(..))
import System.IO (hClose)
import System.IO.Temp (openTempFile)
import System.Directory (getTemporaryDirectory)


type Graph constraint entity = FreeT (Sum Backend (Frontend constraint entity))

runGraphula
  :: (MonadIO m, MonadCatch m)
  => (Frontend constraint entity (m a) -> m a) -> Graph constraint entity m a -> m a
runGraphula frontend f = do
  graphLog <- liftIO $ newIORef ""
  catch (go graphLog) (handleFail graphLog)
  where
    go graphLog =
      flip iterT f $ \case
        InR r -> frontend r
        InL l -> backendArbitrary graphLog l

runGraphulaReplay 
  :: (MonadIO m, MonadCatch m)
  => (Frontend constraint entity (m a) -> m a) -> FilePath -> Graph constraint entity m a -> m a
runGraphulaReplay frontend replayFile f = do
  graphLog <- liftIO $ newIORef ""
  replayLog <- liftIO $ newIORef =<< (lines <$> readFile replayFile)
  catch (go replayLog) (handleFail graphLog)
  where
    go replayLog =
      flip iterT f $ \case
        InR r -> frontend r
        InL l -> backendReplay replayLog l


backendArbitrary :: (MonadThrow m, MonadIO m) => IORef ByteString -> Backend (m b) -> m b
backendArbitrary graphLog = \case
  GenerateNode next -> do
    a <- liftIO . generate $ arbitrary
    liftIO $ modifyIORef' graphLog (<> (toStrict (encode a) <> "\n"))
    next a
  Throw e next ->
    next =<< throwM e

backendReplay :: (MonadThrow m, MonadIO m) => IORef [ByteString] -> Backend (m b) -> m b
backendReplay replayRef = \case
  GenerateNode next -> do
    jsonNode <- liftIO $ do
      (jsonNode:rest) <- readIORef replayRef
      writeIORef replayRef rest
      pure jsonNode
    case eitherDecode $ fromStrict jsonNode of
      Left err -> throwM $ userError err
      Right a -> next a
  Throw e next ->
    next =<< throwM e

handleFail :: (MonadIO m, MonadThrow m) => IORef ByteString -> HUnitFailure -> m a
handleFail graphLog (HUnitFailure l r) = do
  path <- graphToTempFile graphLog
  throwM $ HUnitFailure l $ Reason
     $ "Graph dumped in temp file: " ++ path  ++ "\n\n"
    ++ formatFailureReason r

graphToTempFile :: (MonadIO m) => IORef ByteString -> m FilePath
graphToTempFile graphLog =
  liftIO $ bracket
    (flip openTempFile "fail-.graphula" =<< getTemporaryDirectory)
    (hClose . snd)
    (\(path, handle) -> readIORef graphLog >>= hPutStr handle >> pure path )

liftLeft :: (Monad m, Functor f, Functor g) => FreeT f m a -> FreeT (Sum f g) m a
liftLeft = transFreeT InL

liftRight :: (Monad m, Functor f, Functor g) => FreeT g m a -> FreeT (Sum f g) m a
liftRight = transFreeT InR


data Frontend (constraint :: * -> Constraint) entity next where
  Insert :: constraint a => a -> (Maybe (entity a) -> next) -> Frontend constraint entity next

deriving instance Functor (Frontend constraint entity)

insert :: (Monad m, constraint a) => a -> Graph constraint entity m (Maybe (entity a))
insert n = liftRight $ liftF (Insert n id)


data Backend next where
  GenerateNode :: (ToJSON a, FromJSON a, Arbitrary a) => (a -> next) -> Backend next
  Throw :: Exception e => e -> (a -> next) -> Backend next

deriving instance Functor Backend

generateNode :: (Monad m, ToJSON a, FromJSON a, Arbitrary a) => Graph constraint entity m a
generateNode = liftLeft . liftF $ GenerateNode id

throw :: (Monad m, Exception e) => e -> Graph constraint entity m a
throw e = liftLeft . liftF $ Throw e id

class NoConstraint a where

instance NoConstraint a where

class HasDependencies a where
  type Dependencies a
  type instance Dependencies a = ()

  dependsOn :: a -> Dependencies a -> a
  default dependsOn
    ::
      ( HasEot a
      , HasEot (Dependencies a)
      , GHasDependencies (Proxy a) (Proxy (Dependencies a)) (Eot a) (Eot (Dependencies a))
      )
    => a -> Dependencies a -> a
  dependsOn a dependencies =
    fromEot $
      genericDependsOn
        (Proxy :: Proxy a)
        (Proxy :: Proxy (Dependencies a))
        (toEot a)
        (toEot dependencies)

-- This looks over-specified, but we can have overlap in a type-family
-- and then we avoid overlap in the type-classes below
data Match t = NoMatch t | Match t
data List a = None | Last a | Cons a (List a)

type family FindMatches asTy dsTy as ds where
  -- Excess dependencies
  FindMatches asTy dsTy () (d, ds) = TypeError (Text "Excess dependencies " :<>: ShowType dsTy :<>: Text " for type " :<>: ShowType asTy)

  -- No dependencies
  FindMatches asTy dsTy () () = 'None

  -- Last non-match
  FindMatches asTy dsTy (a, ()) () = 'Last ('NoMatch a)

  -- Only non-matches left
  FindMatches asTy dsTy (a, as) () = 'Cons ('NoMatch a) (FindMatches asTy dsTy as ())

  -- Last match
  FindMatches asTy dsTy (a, ()) (a, ()) = 'Last ('Match a)

  -- Match in the middle
  -- If we wanted, we could require the match to be on `Key a` instead of `a`
  FindMatches asTy dsTy (a, as) (a, ds) = 'Cons ('Match a) (FindMatches asTy asTy as ds)

  -- Non-match in the middle
  FindMatches asTy dsTy (a, as) (d, ds) = 'Cons ('NoMatch a) (FindMatches asTy dsTy as (d, ds))

class GHasDependencies p q a d where
  genericDependsOn :: p -> q -> a -> d -> a

class GHasDependenciesRecursive fields a d where
  genericDependsOnRecursive :: fields -> a -> d -> a

instance
  ( FindMatches asTy dsTy as ds ~ fs
  , GHasDependenciesRecursive (Proxy fs) as ds
  ) => GHasDependencies (Proxy asTy) (Proxy dsTy) (Either as Void) (Either ds Void) where
  genericDependsOn _ _ (Left as) (Left ds) = Left (genericDependsOnRecursive (Proxy :: Proxy fs) as ds)
  genericDependsOn _ _ _ _ = error "Impossible"

instance
  ( a ~ d
  , GHasDependenciesRecursive (Proxy fs) as ds
  ) => GHasDependenciesRecursive (Proxy ('Cons ('Match a) fs)) (a, as) (d, ds) where
  genericDependsOnRecursive _ (_, as) (d, ds) = (d, genericDependsOnRecursive (Proxy :: Proxy fs) as ds)

instance
  ( GHasDependenciesRecursive (Proxy fs) as (d, ds)
  ) => GHasDependenciesRecursive (Proxy ('Cons ('NoMatch a) fs)) (a, as) (d, ds) where
  genericDependsOnRecursive _ (a, as) (d, ds) = (a, genericDependsOnRecursive (Proxy :: Proxy fs) as (d, ds))

instance
  ( GHasDependenciesRecursive (Proxy fs) as ()
  ) => GHasDependenciesRecursive (Proxy ('Cons ('NoMatch a) fs)) (a, as) () where
  genericDependsOnRecursive _ (a, as) () = (a, genericDependsOnRecursive (Proxy :: Proxy fs) as ())

instance GHasDependenciesRecursive (Proxy ('Last ('NoMatch a))) (a, ()) () where
  genericDependsOnRecursive _ (a, ()) () = (a, ())

instance (a ~ d) => GHasDependenciesRecursive (Proxy ('Last ('Match a))) (a, ()) (d, ()) where
  genericDependsOnRecursive _ (_, ()) (d, ()) = (d, ())

instance GHasDependenciesRecursive (Proxy 'None) () () where
  genericDependsOnRecursive _ () () = ()

-- For entities that only one dependency
newtype Only a = Only { unOnly :: a }
  deriving (Eq, Show, Ord, Generic, Functor, Foldable, Traversable)

only :: a -> Only a
only = Only

data GenerationFailure =
  GenerationFailureMaxAttempts TypeRep
  deriving (Show, Typeable)

instance Exception GenerationFailure

nodeEditWith
  :: forall a entity constraint m. (Monad m, constraint a, Typeable a, ToJSON a, FromJSON a, Arbitrary a, HasDependencies a)
  => (Dependencies a) -> (a -> a) -> Graph constraint entity m (entity a)
nodeEditWith dependencies edits =
  tryInsert 10 0 $ do
    x <- generateNode
    pure (edits x `dependsOn` dependencies)

nodeWith
  :: forall a entity constraint m. (Monad m, constraint a, Typeable a, ToJSON a, FromJSON a, Arbitrary a, HasDependencies a)
  => (Dependencies a) -> Graph constraint entity m (entity a)
nodeWith = flip nodeEditWith id

nodeEdit
  :: forall a entity constraint m. (Monad m, constraint a, Typeable a, ToJSON a, FromJSON a, Arbitrary a, HasDependencies a, Dependencies a ~ ())
  => (a -> a) -> Graph constraint entity m (entity a)
nodeEdit edits = nodeEditWith () edits

node
  :: forall a entity constraint m. (Monad m, constraint a, Typeable a, ToJSON a, FromJSON a, Arbitrary a, HasDependencies a, Dependencies a ~ ())
  => Graph constraint entity m (entity a)
node = nodeWith ()

tryInsert
  :: forall a entity constraint m. (Monad m, constraint a, Typeable a)
  => Int -> Int -> (Graph constraint entity m a) -> Graph constraint entity m (entity a)
tryInsert maxAttempts currentAttempts source
  | currentAttempts >= maxAttempts =
      throw . GenerationFailureMaxAttempts $ typeRep (Proxy :: Proxy a)
  | otherwise = do
    value <- source
    insert value >>= \case
      Just a -> pure a
      Nothing -> tryInsert maxAttempts (succ currentAttempts) source
