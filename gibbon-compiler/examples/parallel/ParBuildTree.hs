module ParAdd1Tree where

data Tree = Leaf Int
          | Node Int Tree Tree

mkTree_seq :: Int -> Tree
mkTree_seq i =
  if i <= 0
  then Leaf 6765
  else
      let x = mkTree_seq (i-1)
          y = mkTree_seq (i-1)
      in Node i x y

mkTree :: Int -> Tree
mkTree i =
  if i < 19
  then (mkTree_seq i)
  else
      let x = spawn (mkTree (i-1))
          y = mkTree (i-1)
          _ = sync
      in Node i x y

sumTree_seq :: Tree -> Int
sumTree_seq foo =
  case foo of
    Leaf i     -> i
    Node i a b ->
      let x = sumTree_seq a
          y = sumTree_seq b
      in i + x + y

gibbon_main =
  let n = sizeParam
      x = iterate (mkTree n)
  in (sumTree_seq x)
