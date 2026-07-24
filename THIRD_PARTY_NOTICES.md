# Third-Party Notices

`conduck-connect` is a single self-contained Bash script. Its own source code is
licensed under the Apache License 2.0 — see the LICENSE file at the root of this
repository. This file lists the one third-party component embedded in that
script.

The license identity below was verified against the upstream project.

---

## Vendored source

### Project Nayuki QR Code generator (Python) — MIT

- **Component:** QR Code generator library by Project Nayuki
- **Upstream:** <https://www.nayuki.io/page/qr-code-generator-library>
- **Where it lives:** vendored as the Python block near the end of
  `conduck-connect.sh` (the `render_qr` heredoc), with its original license
  header preserved in-file
- **Modifications:** none — used unmodified
- **License:** MIT

The following copyright and permission notice is reproduced verbatim from the
header of the vendored block:

```text
QR Code generator library (Python)

Copyright (c) Project Nayuki. (MIT License)
https://www.nayuki.io/page/qr-code-generator-library

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:
- The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.
- The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall the
  authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising from,
  out of or in connection with the Software or the use or other dealings in the
  Software.
```
