<?php

class X {
  function __destruct() {
 var_dump('done');
 }
}
function f() {
 $x = new X;
 }
function g() {
  var_dump('start');
  f();
  var_dump('end');
}

<<__EntryPoint>>
function main_1844() {
g();
}
