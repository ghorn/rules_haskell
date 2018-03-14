module Main (
    main
  , add_two_hs
) where

foreign export ccall add_two_hs :: Int -> IO Int

add_two_hs :: Int -> IO Int
add_two_hs = return . (+ 2)

main :: IO ()
main = do
  x <- add_two_hs 5
  putStrLn $ "Five plus 2 gives: " ++
    show x ++ ", did you know?"
