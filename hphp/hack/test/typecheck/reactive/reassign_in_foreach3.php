<?hh
class A {
  <<__Rx>>
  public function __construct(public int $x) {}
}

<<__Rx>>
async function f(Rx\AsyncIterator<A> $g): Awaitable<void> {
  $a = HH\Rx\mutable(new A(10));
  $a->x = 100;
  foreach ($g await as $k => $a)
  {
    // ERROR
    $a->x = 42;
  }
}
