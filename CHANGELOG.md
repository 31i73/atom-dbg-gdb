## 1.7.0
* Added: Support for interactive (stdin) console applications in the output panel
* Fixed: Did not display feedback if trying to use breakpoints with an executable without debug symbols
* #### 1.7.1
	* Fixed: `path` parameter was wrongfully required, and would break in weird ways if it missing (for instance with remote debugging)
	* Fixed: Breakpoints would not work if custom commands were used to select a target (custom commands are now executed first, instead)
	* Improved: Error feedback with regard to missing executables and debug info
* #### 1.7.2
	* Fixed: Did not show the output panel in old (pre 1.17) versions of atom
* #### 1.7.3
	* Fixed: Output panel did not always appear on program output
	* Improved: Output panel now autohides on debug end (unless there was new content since the last pause)
* #### 1.7.4
	* Fixed: TTY windows support
* #### 1.7.5
	* Fixed: Error starting a debug in linux
	* Fixed: Would error if attempting to debug in \*nix without the output panel
* #### 1.7.7
	* Added: Breakpoints now work with dynamically loaded libraries ([CedScilab](https://github.com/CedScilab))

## 1.6.0
* Added: `gdb_executable`, `gdb_arguments` and `gdb_commands` parameters
* Fixed: Debugging would fail if the `cwd` wasn't included (this should be optional)
* #### 1.6.1
	* Fixed: Would break if the debugger engaged on threads other than thread 1
* #### 1.6.2
	* Fixed: When executing custom startup commands, would not process the result before starting the next (delayed responses could execute when now in the wrong state)
	* Fixed: Did not work on targets that do not support "run", such as remote targets

## 1.5.0
* Fixed: Console logging did not log all gdb interactions
* Added: Support for environment variables via `env_vars` parameter ([vanossj](https://github.com/vanossj))
* Added: Supports [`dbg`](https://atom.io/packages/dbg) 1.4.0+ (relative paths for config files)

## 1.4.0
* Fixed: Errors would be throw for identifiers containing special characters
* Added: Config option for logging GDB communication to console for bug reporting
* Added: Now properly supports [`dbg`](https://atom.io/packages/dbg) autodetect (will only be used for supported executable files)
* Improved: Stack traces now include `()` after function names

## 1.3.0
* Added: Passing of executable arguments (thanks to [vanossj](https://github.com/vanossj)!)
* Added: Type information for variables
* Added: [`output-panel`](https://atom.io/packages/output-panel) package now also installed as default

## 1.2.0
* Added: Automatic installation of [`dbg`](https://atom.io/packages/dbg) package if not installed
* #### 1.2.1
	* Fixed: Stacktrace displayed the line number twice
	* Fixed: Stack frames did not always display a file icon if a local/available file (now checks for physical file presence)
	* Fixed: stderr was not displayed in [`output-panel`](https://atom.io/packages/output-panel)

## 1.1.0
* Added: Error displaying (error position now highlighed as such and error explanation displayed)
* #### 1.1.1
	* Fixed: *"Interrupt"* error upon pause

## 1.0.0
* Initial stable release
* #### 1.0.3
	* Fixed: Windows file paths were not supported
* #### 1.0.2
	* Fixed: File paths with spaces did not work
* #### 1.0.1
	* Fixed: Windows newlines were not properly supported (`\r\n`)
