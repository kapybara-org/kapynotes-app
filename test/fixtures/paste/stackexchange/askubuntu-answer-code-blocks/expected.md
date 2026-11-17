<!-- read as: html -->
**230**

```bash
gnome-terminal -- command
```

or

```bash
xterm -e command
```

or

```bash
konsole -e command
```

Pretty much

```bash
terminal -e command
```

### To make the terminal stay when the command exits:

In konsole there is a `--noclose` flag.

In xterm, there is a `-hold` flag.

In `gnome-terminal`, go to *Edit* -> *Profile Preferences* -> *Title*. Click the *Command* tab. Select *Hold the terminal* from the drop-down menu labelled *When command exits*. You should create a new profile for that and execute with

```
gnome-terminal --profile=NAMEOFTHEPROFILE -- command
```

[Share](https://askubuntu.com/a/46630)

[Improve this answer](https://askubuntu.com/posts/46630/edit)

[edited Feb 11 at 14:44](https://askubuntu.com/posts/46630/revisions)

[Thibaut Giroud](https://askubuntu.com/users/1668156/thibaut-giroud)

**3**2 bronze badges

answered Jun 2, 2011 at 20:03

[nickguletskii](https://askubuntu.com/users/nickguletskii)

**4,970**3 gold badges25 silver badges29 bronze badges

- 2

  If I try to hold the terminal, I get "child process exited normally with status code 127" – [Darshan Chaudhary](https://askubuntu.com/users/darshan-chaudhary) [CommentedAug 12, 2016 at 7:49](https://askubuntu.com/questions/46627/how-can-i-make-a-script-that-opens-terminal-windows-and-executes-commands-in-the#comment1226624_46630)
- 2

  gnome-terminal does not have the title option any more :( – [törzsmókus](https://askubuntu.com/users/torzsmokus) [CommentedFeb 22, 2017 at 13:04](https://askubuntu.com/questions/46627/how-can-i-make-a-script-that-opens-terminal-windows-and-executes-commands-in-the#comment1383470_46630)
- 1

  @törzsmókus it is 2017 indeed! LTS releases have a 5 year support life. 14.04 does not end until April 2019. [wiki.ubuntu.com/Releases](https://wiki.ubuntu.com/Releases) – [bhass1](https://askubuntu.com/users/bhass1) [CommentedMar 5, 2017 at 22:33](https://askubuntu.com/questions/46627/how-can-i-make-a-script-that-opens-terminal-windows-and-executes-commands-in-the#comment1391237_46630)
- 1

  `gnome-terminal -e command` only works if `command` is quoted. So this does not work: `gnome-terminal -e "echo hello world; sleep 3"` but this does: `gnome-terminal -e "bash -c 'echo hello world; sleep 3'"`. Sigh. – [bgoodr](https://askubuntu.com/users/bgoodr) [CommentedApr 16, 2017 at 19:47](https://askubuntu.com/questions/46627/how-can-i-make-a-script-that-opens-terminal-windows-and-executes-commands-in-the#comment1421597_46630)
- 5

  consider using now: `gnome-terminal -- command ` – [dallonsi](https://askubuntu.com/users/dallonsi) [CommentedJul 1, 2019 at 7:35](https://askubuntu.com/questions/46627/how-can-i-make-a-script-that-opens-terminal-windows-and-executes-commands-in-the#comment1921488_46630)

[Show **6** more comments](https://askubuntu.com/questions/46627/how-can-i-make-a-script-that-opens-terminal-windows-and-executes-commands-in-the#)
