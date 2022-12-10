# bashcup changelog

## Changelog

### v0.6.2 - 2022-12-10

- fix tar error: `--ignore-failed-read` didn't solve it. tar exit's with 1 anyway.
  catch 1 and 0 of tar and move on.

### v0.6.1 - 2022-12-08

- fix tar error: `file changed as we read it` with option `--ignore-failed-read`

### v0.6.0 - 2022-12-05

- initial public commit
