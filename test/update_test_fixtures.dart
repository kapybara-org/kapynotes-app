/// Signing material for the update tests. Nothing here is a secret: the
/// private half of this key was thrown away once the signature below was
/// made.
library;

/// A throwaway key made for these tests with
/// `openssl dsaparam 2048 | openssl gendsa | openssl dsa -pubout`, the same
/// commands — and so the same 2048/224-bit shape — as the real one.
const testUpdateKey = '''
-----BEGIN PUBLIC KEY-----
MIIDQjCCAjUGByqGSM44BAEwggIoAoIBAQCUm7JgXZOLnRf0+OsjYvwHj5jc9V/6
seIvauz8B9AMBw0KlHph3Bc1gWu7RZxyQf0vxwqdGnJtB8qSBk70Z/o7mi4yVGJ9
AH0ZsfD+5f6xAzhqbH17RkpwiJGgFyx+5NVCjBhO4Gcw1oLhEZFsXN8bsL9Ibs7u
UOUH4tls+5IfT767ElzP0NGxcEDUNARNEfhzKZTkUYRVKMc93T1nVN5Gs9nNbvlE
FYSjzLT5yRIDxV/rOl7Y9uokbu5iEibuZj/qquAskfzsiyeX2efCLQVtChxd1xZD
AUfC9HvzD5Vb9NQ0o9wCo6dYv6yroo6p/ibxWMjyfY80Dyv8VbtAREfRAh0A5pbn
6kh9eO2DQgZj5sXzNE4CrYhJ8Wax7hXHQQKCAQBoIPxWauk0w5AzwKMmAI0lRB75
Qq36hG4Jn/VBnSG1WzgDGjw+Ssu9ltFEePyw9ID2O+9INOThCIVfgRJ5/DZimyZH
Kl/E/f+S+19u/OWlUMDVylp9goBjD6JqLixk6JwKYNKF13g6nc2FJ+OQOOdI7qxz
UHEYAaZgcZxhkuGg69zZvaytwd5ciiCxXoWbYSycIoerln3XAWxJdKczqhkmTv7I
MonAAdomCRjGuikM/t0K71NVcJ+PhmXthNu4SKYKuUYsNIOfr/I91OHrnASxLa25
CMDOJD9Wsu4oDudfvLI8dnI/UWS2mkdca1uv6a3xju+OSwc88kROK+S8dEksA4IB
BQACggEAP7vx0IHNo3U0w2AkOxQMy9o2PUV58sqvjmsU1udjcHZS46C7zNIpze8s
C681FGQqOxxVpgjE2fiNoOwu6CrZqn7ArZdsmgqH6DkxH+l+CUaQh4lgFMhE6Ody
+3oMR9FWd93Dh7Uwt41r/fHw37IC0j73PW5vbs1iaRJlSmgri7yVieNSr0G9y85Q
CWgay5qpY2/tj2ehjyC5Q9QEzDbi5LmwMNAG5yfMyMeQKZKZIkiTcWvUQQjXqPBS
y6DuULsTjUt+PGoq1+R/hps1Sjd3i0Lk7IWTiIi1tu2GfEX+cEFL5TrYTLPwEq3H
XSOV9AG0LVQS3VZ2iluO9mkvZKsVFA==
-----END PUBLIC KEY-----
''';

/// Signed with the private half of [testUpdateKey] by the same pipeline the
/// release job runs over the installer.
const testPayload = 'Kapy Notes update test payload\n';
const testPayloadSignature =
    'MD0CHC801NFC2Cq5BqSrRqLFKDMLPvJGAF2GHJP6RkICHQDLdVzyctiZWzAjFi4Y0lMbCn/Gfcqr3sYTwbQi';
