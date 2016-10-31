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
