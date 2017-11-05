<?hh
// Copyright 2004-present Facebook. All Rights Reserved.

class A {
  private static function get(): varray<string> {
    return varray['SP', 'PP', 'SP2', 'PP2', 'I'];
  }

  public async function gen(): Awaitable<array> {
    $x = darray[];
    foreach (self::get() as $t) $x[$t] = 'N/A';
    return $x;
  }
}

$a = new A;
var_dump(\HH\Asio\join($a->gen()));
