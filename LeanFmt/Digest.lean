/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import Lean.Data.Json

namespace LeanFmt

/-- A lowercase SHA-256 digest. The constructor stays private so identities cannot contain
malformed or truncated digests. -/
structure Digest where
  private mk ::
  hex : String
  deriving BEq, DecidableEq, Repr

namespace Digest

private def roundConstants : Array UInt32 := #[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]

private def initialState : Array UInt32 := #[
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
]

private def rotateRight (value amount : UInt32) : UInt32 :=
  (value.shiftRight amount).lor (value.shiftLeft (32 - amount))

private def choose (x y z : UInt32) : UInt32 :=
  (x.land y).xor (x.complement.land z)

private def majority (x y z : UInt32) : UInt32 :=
  (x.land y).xor ((x.land z).xor (y.land z))

private def largeSigma0 (x : UInt32) : UInt32 :=
  (rotateRight x 2).xor ((rotateRight x 13).xor (rotateRight x 22))

private def largeSigma1 (x : UInt32) : UInt32 :=
  (rotateRight x 6).xor ((rotateRight x 11).xor (rotateRight x 25))

private def smallSigma0 (x : UInt32) : UInt32 :=
  (rotateRight x 7).xor ((rotateRight x 18).xor (x.shiftRight 3))

private def smallSigma1 (x : UInt32) : UInt32 :=
  (rotateRight x 17).xor ((rotateRight x 19).xor (x.shiftRight 10))

private def padded (input : ByteArray) : ByteArray := Id.run do
  let bitLength := input.size.toUInt64 * 8
  let mut bytes := input.push 0x80
  while bytes.size % 64 != 56 do
    bytes := bytes.push 0
  for shift in #[56, 48, 40, 32, 24, 16, 8, 0] do
    bytes := bytes.push ((bitLength.shiftRight shift.toUInt64).toUInt8)
  return bytes

private def wordAt (bytes : ByteArray) (offset : Nat) : UInt32 :=
  let b0 := (bytes.get! offset).toUInt32.shiftLeft 24
  let b1 := (bytes.get! (offset + 1)).toUInt32.shiftLeft 16
  let b2 := (bytes.get! (offset + 2)).toUInt32.shiftLeft 8
  let b3 := (bytes.get! (offset + 3)).toUInt32
  b0.lor (b1.lor (b2.lor b3))

private def schedule (bytes : ByteArray) (offset : Nat) : Array UInt32 := Id.run do
  let mut words := Array.replicate 64 0
  for i in [0:16] do
    words := words.set! i (wordAt bytes (offset + i * 4))
  for i in [16:64] do
    let next := smallSigma1 words[i - 2]! + words[i - 7]! +
      smallSigma0 words[i - 15]! + words[i - 16]!
    words := words.set! i next
  return words

private def compress (state : Array UInt32) (words : Array UInt32) : Array UInt32 := Id.run do
  let mut a := state[0]!
  let mut b := state[1]!
  let mut c := state[2]!
  let mut d := state[3]!
  let mut e := state[4]!
  let mut f := state[5]!
  let mut g := state[6]!
  let mut h := state[7]!
  for i in [0:64] do
    let t1 := h + largeSigma1 e + choose e f g + roundConstants[i]! + words[i]!
    let t2 := largeSigma0 a + majority a b c
    h := g
    g := f
    f := e
    e := d + t1
    d := c
    c := b
    b := a
    a := t1 + t2
  return #[
    state[0]! + a, state[1]! + b, state[2]! + c, state[3]! + d,
    state[4]! + e, state[5]! + f, state[6]! + g, state[7]! + h
  ]

private def hashBytes (input : ByteArray) : Array UInt32 := Id.run do
  let bytes := padded input
  let mut state := initialState
  for block in [0:bytes.size / 64] do
    state := compress state (schedule bytes (block * 64))
  return state

private def appendWordHex (output : String) (word : UInt32) : String := Id.run do
  let mut result := output
  for shift in #[28, 24, 20, 16, 12, 8, 4, 0] do
    let nibble := (word.shiftRight shift).land 0xf
    result := result.push (Nat.digitChar nibble.toNat)
  return result

/-- Hash an exact byte sequence. Only the bytes; no filesystem metadata. -/
def ofBytes (bytes : ByteArray) : Digest :=
  let hex := (hashBytes bytes).foldl appendWordHex ""
  .mk hex

/-- Hash exact UTF-8 source bytes. No newline normalization happens first. -/
def ofString (source : String) : Digest :=
  ofBytes source.toUTF8

/-- Parse an externally supplied digest only when it is exactly 64 lowercase hexadecimal digits. -/
def parse? (value : String) : Option Digest :=
  if value.length == 64 && value.toList.all fun char =>
      ('0' ≤ char && char ≤ '9') || ('a' ≤ char && char ≤ 'f') then
    some (.mk value)
  else
    none

instance : ToString Digest := ⟨Digest.hex⟩

instance : Lean.ToJson Digest := ⟨fun digest => .str digest.hex⟩

instance : Lean.FromJson Digest where
  fromJson? json := do
    let value ← Lean.fromJson? json
    match parse? value with
    | some digest => pure digest
    | none => throw "expected a 64-digit lowercase SHA-256 digest"

end Digest

end LeanFmt
