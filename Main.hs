module Main where

import Control.Monad.Trans.Reader
import Control.Monad.Error
import Data.List
import System.Directory
import System.Environment
import System.Console.GetOpt
import System.Console.Haskeline

import Exp.Lex
import Exp.Par
import Exp.Print
import Exp.Abs hiding (NoArg)
import Exp.Layout
import Exp.ErrM
import Concrete hiding (getConstrs)
import qualified TypeChecker as TC
import qualified CTT as C
import qualified Eval as E

type Interpreter a = InputT IO a

-- Flag handling
data Flag = Debug
  deriving (Eq,Show)

options :: [OptDescr Flag]
options = [ Option "d" ["debug"] (NoArg Debug) "Run in debugging mode" ]

parseOpts :: [String] -> IO ([Flag],[String])
parseOpts argv = case getOpt Permute options argv of
  (o,n,[])   -> return (o,n)
  (_,_,errs) -> ioError (userError (concat errs ++ usageInfo header options))
    where header = "Usage: cubical [OPTION...] [FILES...]"

defaultPrompt :: String
defaultPrompt = "> "

lexer :: String -> [Token]
lexer = resolveLayout True . myLexer

showTree :: (Show a, Print a) => a -> IO ()
showTree tree = do
  putStrLn $ "\n[Abstract Syntax]\n\n" ++ show tree
  putStrLn $ "\n[Linearized tree]\n\n" ++ printTree tree

-- Used for auto completion
searchFunc :: [String] -> String -> [Completion]
searchFunc ns str = map simpleCompletion $ filter (str `isPrefixOf`) ns

settings :: [String] -> Settings IO
settings ns = Settings
  { historyFile    = Nothing
  , complete       = completeWord Nothing " \t" $ return . searchFunc ns
  , autoAddHistory = True }

main :: IO ()
main = do
  args <- getArgs
  (flags,files) <- parseOpts args
  -- Should it run in debugging mode?
  let b = Debug `elem` flags
  case files of
    [f] -> initLoop b f
    _   -> do putStrLn $ "Exactly one file expected: " ++ show files
              runInputT (settings []) (loop b [] [] TC.tEmpty)

-- (not ok,loaded,already loaded defs) -> to load -> (newnotok, newloaded, newdefs)
imports :: ([String],[String],[Def]) -> String -> IO ([String],[String],[Def])
imports st@(notok,loaded,defs) f
  | f `elem` notok  = putStrLn ("Looping imports in " ++ f) >> return ([],[],[])
  | f `elem` loaded = return st
  | otherwise       = do
    b <- doesFileExist f
    if not b
      then putStrLn (f ++ " does not exist") >> return ([],[],[])
      else do
        s <- readFile f
        let ts = lexer s
        case pModule ts of
          Bad s  -> do
            putStrLn $ "Parse failed in " ++ show f ++ "\n" ++ show s
            return ([],[],[])
          Ok mod@(Module _ imps defs') -> do
            let imps' = [ unIdent s ++ ".cub" | Import s <- imps ]
            (notok1,loaded1,def1) <- foldM imports (f:notok,loaded,defs) imps'
            putStrLn $ "Parsed " ++ show f ++ " successfully!"
            return (notok,f:loaded1,def1 ++ defs')

getConstrs :: [Def] -> [String]
getConstrs []                  = []
getConstrs (DefData _ _ ls:ds) = [ unIdent n | Sum n _ <- ls] ++ getConstrs ds
getConstrs (DefMutual ds:ds')  = getConstrs ds ++ getConstrs ds'
getConstrs (_:ds)              = getConstrs ds

namesEnv :: TC.TEnv -> [String]
namesEnv (TC.TEnv _ env ctxt) = namesCEnv env ++ map fst ctxt
  where namesCEnv C.Empty          = []
        namesCEnv (C.Pair e (b,_)) = namesCEnv e ++ [b]
        namesCEnv (C.PDef xs e)    = map fst xs ++ namesCEnv e

-- Initialize the main loop
initLoop :: Bool -> FilePath -> IO ()
initLoop debug f = do
  -- Parse and type-check files
  (_,_,defs) <- imports ([],[],[]) f
  -- Compute all constructors
  let cs  = getConstrs defs
  -- Translate to CTT
  let res = runResolver (local (insertConstrs cs) (resolveDefs defs))
  case res of
    Left err    -> do
      putStrLn $ "Resolver failed: " ++ err
      runInputT (settings []) (loop debug [] [] TC.tEmpty)
    Right adefs -> case TC.runDefs TC.tEmpty adefs of
      Left err   -> do
        putStrLn $ "Type checking failed: " ++ err
        runInputT (settings []) (loop debug [] [] TC.tEmpty)
      Right (tenv,TC.TState ttrc ftrc) -> do
        -- In debugging mode output full trace
        when debug $ putStr (unlines ftrc)
        -- Otherwise output only trace from type checking
        when (not debug) $ putStr (unlines ttrc)
        putStrLn "File loaded."
        -- Compute names for auto completion
        let ns = cs ++ namesEnv tenv
        runInputT (settings ns) (loop debug f cs tenv)

-- The main loop
loop :: Bool -> FilePath -> [String] -> TC.TEnv -> Interpreter ()
loop debug f cs tenv@(TC.TEnv _ rho _) = do
  input <- getInputLine defaultPrompt
  case input of
    Nothing    -> outputStrLn help >> loop debug f cs tenv
    Just ":q"  -> return ()
    Just ":r"  -> lift $ initLoop debug f
    Just (':':'l':' ':str)
      | ' ' `elem` str -> do outputStrLn "Only one file allowed after :l"
                             loop debug f cs tenv
      | otherwise      -> lift $ initLoop debug str
    Just (':':'c':'d':' ':str) -> do lift (setCurrentDirectory str)
                                     loop debug f cs tenv
    Just ":h"  -> outputStrLn help >> loop debug f cs tenv
    Just str   -> case pExp (lexer str) of
      Bad err -> outputStrLn ("Parse error: " ++ err) >> loop debug f cs tenv
      Ok  exp -> case runResolver (local (const (Env cs)) (resolveExp exp)) of
        Left  err  -> do outputStrLn ("Resolver failed: " ++ err)
                         loop debug f cs tenv
        Right body -> case TC.runInfer tenv body of
          Left err -> do outputStrLn ("Could not type-check: " ++ err)
                         loop debug f cs tenv
          Right _  -> do
            let (e,trace) = E.evalTer rho body
            when debug $ outputStr (unlines trace)
            outputStrLn ("EVAL: " ++ show e)
            loop debug f cs tenv

help :: String
help = "\nAvailable commands:\n" ++
       "  <statement>     infer type and evaluate statement\n" ++
       "  :q              quit\n" ++
       "  :l <filename>   loads filename (and resets environment before)\n" ++
       "  :cd <path>      change directory to path\n" ++
       "  :r              reload\n" ++
       "  :h              display this message\n"
