module Seq2DCorr where

coord :: Int -> (Float, Float, Float) -> Float
coord axis pt =
  if axis == 0
  then pt !!! 0
  else if axis == 1
  then pt !!! 1
  else pt !!! 2

getNextAxis_2D :: Int -> Int
getNextAxis_2D i = mod (i + 1) 2

min :: Float -> Float -> Float
min a b = if a .<. b then a else b

max :: Float -> Float -> Float
max a b = if a .>. b then a else b

cmp1 :: (Float, Float, Float) -> (Float, Float, Float) -> Int
cmp1 a b = floatToInt ((a !!! 0) .-. (b !!! 0))

cmp2 :: (Float, Float, Float) -> (Float, Float, Float) -> Int
cmp2 a b = floatToInt ((a !!! 1) .-. (b !!! 1))

cmp3 :: (Float, Float, Float) -> (Float, Float, Float) -> Int
cmp3 a b = floatToInt ((a !!! 2) .-. (b !!! 2))

sort :: Int -> [(Float, Float, Float)] -> [(Float, Float, Float)]
sort axis ls =
    if axis == 0
    -- This isn't safe, but avoids memory blowup
    then let _ = inplacevsort ls cmp1
         in ls
    else if axis == 1
    then let _ = inplacevsort ls cmp2
         in ls
    else let _ = inplacevsort ls cmp3
         in ls

--------------------------------------------------------------------------------
-- The main algorithm

data KdTree = KdLeaf Float  -- ^ x coord
                     Float  -- ^ y coord
                     Float  -- ^ z coord

            | KdNode Int    -- ^ number of elements in this node
                     Int    -- ^ splitting axis (0 == x, 1 == y)
                     Float  -- ^ split value
                     Float  -- ^ min_x
                     Float  -- ^ max_x
                     Float  -- ^ min_y
                     Float  -- ^ max_y
                     Float  -- ^ min_z
                     Float  -- ^ max_z
                     KdTree -- ^ left
                     KdTree -- ^ right
  deriving Show

getMinX :: KdTree -> Float
getMinX tr =
  case tr of
    KdNode _ _ _ min_x _ _ _ _ _ _ _ -> min_x
    KdLeaf x _ _                     -> x

getMaxX :: KdTree -> Float
getMaxX tr =
  case tr of
    KdNode _ _ _ _ max_x _ _ _ _ _ _ -> max_x
    KdLeaf x _ _                     -> x

getMinY :: KdTree -> Float
getMinY tr =
  case tr of
    KdNode _ _ _ _ _ min_y _ _ _ _ _ -> min_y
    KdLeaf _ y _                     -> y

getMaxY :: KdTree -> Float
getMaxY tr =
  case tr of
    KdNode _ _ _ _ _ _ max_y _ _ _ _ -> max_y
    KdLeaf _ y _                     -> y

getMinZ :: KdTree -> Float
getMinZ tr =
  case tr of
    KdNode _ _ _ _ _ _ _ min_z _ _ _ -> min_z
    KdLeaf _ _ z                     -> z

getMaxZ :: KdTree -> Float
getMaxZ tr =
  case tr of
    KdNode _ _ _ _ _ _ _ _ max_z _ _ -> max_z
    KdLeaf _ _ z                     -> z


getElems :: KdTree -> Int
getElems tr =
  case tr of
    KdNode elems _ _ _ _ _ _ _ _ _ _ -> elems
    KdLeaf _ y _                     -> 1


fromListWithAxis :: Int -> [(Float, Float, Float)] -> KdTree
fromListWithAxis axis pts =
    let len = vlength pts in
    if len == 1
    then let pt = vnth 0 pts
         in KdLeaf (pt !!! 0) (pt !!! 1) (pt !!! 2)
    else let sorted_pts = sort axis pts
             pivot_idx  = div len 2
             pivot      = vnth pivot_idx sorted_pts
             left_pts   = vslice sorted_pts 0 pivot_idx
             right_pts  = vslice sorted_pts pivot_idx len
             next_axis  = getNextAxis_2D axis
             left_tr    = fromListWithAxis next_axis left_pts
             right_tr   = fromListWithAxis next_axis right_pts
             min_x      = min (getMinX left_tr) (getMinX right_tr)
             max_x      = max (getMaxX left_tr) (getMaxX right_tr)
             min_y      = min (getMinY left_tr) (getMinY right_tr)
             max_y      = max (getMaxY left_tr) (getMaxY right_tr)
             min_z      = min (getMinZ left_tr) (getMinZ right_tr)
             max_z      = max (getMaxZ left_tr) (getMaxZ right_tr)
             total_elems= (getElems left_tr) + (getElems right_tr)
         in KdNode total_elems axis (coord axis pivot) min_x max_x min_y max_y min_z max_z left_tr right_tr

-- | Build a KD-Tree out of a set of points
fromList :: [(Float, Float, Float)] -> KdTree
fromList pts = fromListWithAxis 0 pts


--------------------------------------------------------------------------------

{-

-- | Return the point that is closest to a
least_dist :: (Int, Int) -> (Int, Int) -> (Int, Int) -> (Int, Int)
least_dist a b c =
  let d1 = dist a b
      d2 = dist a c
  in if d1 < d2 then b else c

-- | Return the nearest neighbor of probe
nearest :: KdTree -> (Int, Int) -> (Int, Int)
nearest tr probe =
  case tr of
    KdEmpty -> (-100,-100)
    KdNode axis pivot_x pivot_y left right ->
      let pivot   =  (pivot_x, pivot_y)
          tst_probe = coord axis probe
          tst_pivot = coord axis pivot
      in
      if tst_probe < tst_pivot
      then find_nearest pivot probe tst_pivot tst_probe left right
      else find_nearest pivot probe tst_pivot tst_probe right left

-- | Find the closest point to probe in a KD-tree
find_nearest :: (Int, Int) -> (Int, Int) -> Int -> Int -> KdTree -> KdTree -> (Int, Int)
find_nearest pivot probe tst_pivot tst_probe side other =
  let best0 = nearest side probe
      candidate1 = least_dist probe best0 pivot
      -- whether the difference between the splitting coordinate of the search point and current node
      -- is less than the distance (overall coordinates) from the search point to the current best.
  in if ((tst_probe - tst_pivot) ^ 2) <= dist probe candidate1
     then let candidate2   = nearest other probe
              best1 = least_dist probe candidate1 candidate2
          in best1
     else candidate1

-}

-- | Sum of all points in KD-Tree
sumKdTree :: KdTree -> Float
sumKdTree tr =
  case tr of
    KdLeaf x y z -> x .+. y .+. z
    KdNode _ _ _ _ _ _ _ _ _ left right ->
      let o = sumKdTree left
          p = sumKdTree right
      in o .+. p

sumList0 :: Int -> Int -> [(Float, Float, Float)] -> Float -> Float
sumList0 i n ls acc =
  if i == n
  then acc
  else let p = vnth i ls
       in sumList0 (i+1) n ls (acc .+. (p !!! 0) .+. (p !!! 1) .+. (p !!! 2))

sumList :: [(Float, Float, Float)] -> Float
sumList ls =
  sumList0 0 (vlength ls) ls 0.0

-- | Distance between two points
dist :: (Float, Float, Float) -> (Float, Float, Float) -> Float
dist a b =
  let a_x = a !!! 0
      a_y = a !!! 1
      a_z = a !!! 2
      b_x = b !!! 0
      b_y = b !!! 1
      b_z = b !!! 2
      d1 = (a_x .-. b_x)
      d2 = (a_y .-. b_y)
      d3 = (a_z .-. b_z)
  in (d1 .*. d1) .+. (d2 .*. d2) .+. (d3 .*. d3)


-- | Two point correlation
countCorr :: (Float, Float, Float) -> Float -> KdTree -> Int
countCorr probe radius tr =
  case tr of
    KdLeaf x y z ->
      if (dist probe (x, y, z)) .<. (radius .*. radius)
      then 1
      else 0

    KdNode elems axis split_val min_x max_x min_y max_y min_z max_z left right ->
      -- Ported over from ASTBenchmarks
      let center_x  = (min_x .+. max_x) ./. 2.0
          center_y  = (min_y .+. max_y) ./. 2.0
          center_z  = (min_z .+. max_z) ./. 2.0
          d_x       = (probe !!! 0) .-. center_x
          d_y       = (probe !!! 1) .-. center_y
          d_z       = (probe !!! 2) .-. center_z
          boxdist_x = (max_x .-. min_x) ./. 2.0
          boxdist_y = (max_y .-. min_y) ./. 2.0
          boxdist_z = (max_z .-. min_z) ./. 2.0
          sum       = (d_x .*. d_x) .+. (d_y .*. d_y) .+. (d_z .*. d_z)
          boxsum    = (boxdist_x .*. boxdist_x) .+. (boxdist_y .*. boxdist_y) .+. (boxdist_z .*. boxdist_z)
      in if (sum .-. boxsum) .<. (radius .*. radius)
         then let n1 = countCorr probe radius left
                  n2 = countCorr probe radius right
              in n1 + n2
         else 0

--------------------------------------------------------------------------------

gibbon_main =
    let pts :: [(Float, Float, Float)]
        pts = readArrayFile ()
        n       = sizeParam
        radius  = intToFloat n
        tr      = fromList pts
        i       = rand
        j       = (mod i n) - 1
        probe   = vnth j pts
    in iterate (countCorr probe radius tr)
