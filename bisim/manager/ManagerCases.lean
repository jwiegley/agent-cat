import ManagerConformance.Cases

/-!
# The writer of the retained manager cases

`lake --dir bisim exe manager-cases bisim/manager/cases` writes, for each case
of `ManagerConformance.Cases`, the file `<name>.request.json` with the encoded
request and the file `<name>.expected.json` with the response of the oracle.
Each file holds one line. The `#guard` commands of `ManagerConformance.Cases`
fix the outcome of every case, so this writer only renders them. A rewrite of
the directory must leave every file unchanged unless the encoding or a case
changes.
-/

open ManagerConformance ManagerConformance.Cases

def write (dir : System.FilePath) (name request : String) : IO Unit := do
  IO.FS.writeFile (dir / s!"{name}.request.json") (request ++ "\n")
  IO.FS.writeFile (dir / s!"{name}.expected.json") ((respondLine request).compress ++ "\n")

def main (args : List String) : IO UInt32 := do
  let [dir] := args | do
    IO.eprintln "usage: manager-cases DIRECTORY"
    return 2
  IO.FS.createDirAll dir
  for c in cases do
    write dir c.name (encodeQuery c.query).compress
  for (name, text) in malformed do
    write dir name text
  return 0
