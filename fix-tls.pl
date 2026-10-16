# fix-tls.pl — обнуляет пустую TLS-директорию FPC-бинарника,
# чтобы UPX 5.2+ мог его упаковать (ошибка "TLS empty region").
# Использование: perl fix-tls.pl mdview.exe
use strict; use warnings;
my $file = $ARGV[0] or die "usage: perl fix-tls.pl <exe>\n";
open(my $F, '+<', $file) or die "$file: $!\n";
binmode $F;
seek($F, 0x3c, 0); read($F, my $b, 4);
my $pe = unpack('V', $b);
seek($F, $pe + 24 + 96 + 9*8, 0);          # DataDirectory[IMAGE_DIRECTORY_ENTRY_TLS]
read($F, my $t, 8);
my ($rva, $sz) = unpack('VV', $t);
if ($rva == 0 && $sz == 0) { print "TLS dir already empty\n"; exit 0; }
seek($F, $pe + 24 + 96 + 9*8, 0);
print $F "\0" x 8;
printf "TLS dir zeroed (was rva=%x size=%x)\n", $rva, $sz;
