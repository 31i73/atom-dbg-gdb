parseMi2 = require './parseMi2'
fs = require 'fs'
path = require 'path'
{BufferedProcess, CompositeDisposable, Emitter} = require 'atom'

escapePath = (path) ->
	return (path.replace /\\/g, '/').replace /[\s\t\n]/g, '\\ '

prettyValue = (value) ->
	return (value.replace /({|,)/g, '$1\n').replace /(})/g, '\n$1' # split gdb's summaries onto multiple lines, at commas and braces. An ugly hack, but it'll do for now

module.exports = DbgGdb =
	config:
		logToConsole:
			title: 'Log to developer console'
			description: 'For debugging GDB problems'
			type: 'boolean'
			default: false
	dbg: null
	logToConsole: false
	breakpoints: []
	ui: null
	process: null
	processAwaiting: false
	processQueued: []
	variableObjects: {}
	variableRootObjects: {}
	errorEncountered: null
	thread: 1
	frame: 0
	outputPanel: null
	showOutputPanelNext: false # is the output panel scheduled to be displayed on next print?
	unseenOutputPanelContent: false # has there been program output printed since the program was last paused?
	closedNaturally: false # did the program naturally terminate, while not paused?
	interactiveSession: null
	miEmitter: null

	activate: (state) ->
		require('atom-package-deps').install('dbg-gdb')

		atom.config.observe 'dbg-gdb.logToConsole', (set) =>
			@logToConsole = set

	consumeOutputPanel: (outputPanel) ->
		@outputPanel = outputPanel

	debug: (options, api) ->
		@ui = api.ui
		@breakpoints = api.breakpoints
		@outputPanel?.clear()

		@start options

		@miEmitter.on 'exit', =>
			@ui.stop()

		@miEmitter.on 'console', (line) =>
			if @outputPanel
				if @showOutputPanelNext
					@showOutputPanelNext = false
					@outputPanel.show()
				@outputPanel.print '\x1b[37;40m'+line.replace(/([^\r\n]+)\r?\n/,'\x1b[0K$1\r\n')+'\x1b[39;49m', false

		@miEmitter.on 'result', ({type, data}) =>
			switch type
				when 'running'
					@ui.running()

		@miEmitter.on 'exec', ({type, data}) =>
			switch type
				when 'running'
					@ui.running()

				when 'stopped'
					if data['thread-id']
						@thread = parseInt data['thread-id'], 10
						# @ui.setThread @thread

					switch data.reason
						when 'exited-normally'
							@closedNaturally = true
							@ui.stop()
							return

						# when 'exited-signalled'
							# TODO: Somehow let dbg know we can't continue. Our only option from here is to stop
							# although leave paused for now so the exit state can be inspected

						when 'signal-received'
							if data['signal-name'] != 'SIGINT'
								@errorEncountered = data['signal-meaning'] or if data['signal-name'] then data['signal-name']+'signal received' else 'Signal received'
								@ui.showError @errorEncountered

					@unseenOutputPanelContent = false
					@ui.paused()

					@sendCommand '-stack-list-frames --thread '+@thread
						.then ({type, data}) =>
							stack = []
							lastValid = false
							@stackList = data.stack
							if data.stack.length>0 then for i in [0..data.stack.length-1]
								frame = data.stack[i]
								description

								name = ''
								if frame.func
									name = frame.func+'()'
								else
									name = frame.addr

								framePath = ''
								if frame.file
									framePath = frame.file.replace /^\.\//, ''
								else
									framePath = frame.from
									if frame.addr
										framePath += ':'+frame.addr

								description = name + ' - ' + framePath

								atom.project.getPaths()[0]

								isLocal = false
								if frame.file
									if frame.file.match /^\.\//
										isLocal = true
									else if fs.existsSync(atom.project.getPaths()[0]+'/'+frame.file)
										isLocal = true

								if isLocal and lastValid==false #get the first valid as the last, as this list is reversed
									lastValid = i

								stack.unshift
									local: isLocal
									file: frame.fullname
									line: if frame.line then parseInt(frame.line) else undefined
									name: name
									path: framePath
									error: if i==0 then @errorEncountered else undefined

							@ui.setStack stack
							# if lastValid!=false
							# 	@frame = lastValid
							# 	@ui.setFrame stack.length-1-lastValid #reverse it
							# 	@refreshFrame()

							@frame = 0
							@refreshFrame()

		task = Promise.resolve()

		if options.path
			task = task.then => @sendCommand '-file-exec-and-symbols '+escapePath (path.resolve options.basedir||'', options.path)

		task = task.then =>
			begin = () =>
				@sendCommand 'set environment ' + env_var for env_var in options.env_vars if options.env_vars?

				task = Promise.resolve()

				for command in [].concat options.gdb_commands||[]
					do (command) =>
						task = task.then => @sendCommand command

				show_breakpoint_warning = false
				for breakpoint in @breakpoints
					task = task.then =>
						@sendCommand '-break-insert -f '+(escapePath breakpoint.path)+':'+breakpoint.line, (log) =>
							if log.match /no symbol table is loaded/i
								show_breakpoint_warning = true

				started = =>
					if show_breakpoint_warning
						atom.notifications.addError 'Error inserting breakpoints',
							description: 'This program was not compiled with debug symbols.  \nBreakpoints cannot be used.'
							dismissable: true

				task = task.then =>
					@sendCommand '-exec-arguments ' + options.args.join(" ") if options.args?
					@sendCommand '-exec-run'
						.then =>
							started()
						, (error) =>
							if typeof error != 'string' then return
							if error.match /target does not support "run"/
								@sendCommand '-exec-continue'
									.then =>
										started()
									, (error) =>
										if typeof error != 'string' then return
										@handleMiError error, 'Unable to debug this with GDB'
										@dbg.stop()
								return

							else if error.match /no executable file specified/i
								atom.notifications.addError 'Nothing to debug',
									description: 'Nothing was specified for GDB to debug. Specify a `path`, or `gdb_commands` to select a target'
									dismissable: true

							else
								@handleMiError error, 'Unable to debug this with GDB'

							@dbg.stop()

			@sendCommand '-gdb-set mi-async on'
				.then => begin()
				.catch =>
					@sendCommand '-gdb-set target-async on'
						.then => begin()
						.catch (error) =>
							if typeof error != 'string' then return
							@handleMiError error, 'Unable to debug this with GDB'
							@dbg.stop()

		task.catch (error) =>
			if typeof error != 'string' then return
			if error.match /not in executable format/i
				atom.notifications.addError 'This file cannot be debugged',
					description: 'It is not recognised by GDB as a supported executable file'
					dismissable: true
			else
				@handleMiError error, 'Unable to debug this with GDB'
			@dbg.stop()

	cleanupFrame: ->
		@errorEncountered = null
		return Promise.all (@sendCommand '-var-delete '+var_name for name, var_name of @variableRootObjects)
			.then =>
				@variableObjects = {}
				@variableRootObjects = {}

	start: (options)->
		@showOutputPanelNext = true
		@unseenOutputPanelContent = false
		@closedNaturally = false
		@outputPanel?.clear()

		matchAsyncHeader = /^([\^=*+])(.+?)(?:,(.*))?$/
		matchStreamHeader = /^([~@&])(.*)?$/

		command = options.gdb_executable||'gdb'
		cwd = path.resolve options.basedir||'', options.cwd||''

		handleError = (message) =>
			atom.notifications.addError 'Error running GDB',
				description: message
				dismissable: true

			@ui.stop()

		if !fs.existsSync cwd
			handleError "Working directory is invalid:  \n`#{cwd}`"
			return

		args = ['-quiet','--interpreter=mi2']

		if @outputPanel and @outputPanel.getInteractiveSession
			interactiveSession = @outputPanel.getInteractiveSession()
			if interactiveSession.pty
				@interactiveSession = interactiveSession

		if @interactiveSession
			args.push '--tty='+@interactiveSession.pty.pty
			@interactiveSession.pty.on 'data', (data) =>
				if @showOutputPanelNext
					@showOutputPanelNext = false
					@outputPanel.show()
				@unseenOutputPanelContent = true

		else if process.platform=='win32'
			options.gdb_commands = ([].concat options.gdb_commands||[]).concat 'set new-console on'

		args = args.concat options.gdb_arguments||[]

		@miEmitter = new Emitter()
		@process = new BufferedProcess
			command: command
			args: args
			options:
				cwd: cwd
			stdout: (data) =>
				for line in data.replace(/\r?\n$/,'').split(/\r?\n/)
					if match = line.match matchAsyncHeader
						type = match[2]
						data = if match[3] then parseMi2 match[3] else {}

						if @logToConsole then console.log 'dbg-gdb < ',match[1],type,data

						switch match[1]
							when '^' then @miEmitter.emit 'result' , {type:type, data:data}
							when '=' then @miEmitter.emit 'notify' , {type:type, data:data}
							when '*' then @miEmitter.emit 'exec'   , {type:type, data:data}
							when '+' then @miEmitter.emit 'status' , {type:type, data:data}

					else if match = line.match matchStreamHeader
						data = parseMi2 match[2]
						data = if data then data._ else ''

						if @logToConsole then console.log 'dbg-gdb < ',match[1],data

						switch match[1]
							when '~' then @miEmitter.emit 'console', data.trim()
							when '&' then @miEmitter.emit 'log', data.trim()
					else
						if line!='(gdb)' and line!='(gdb) '
							if @logToConsole then console.log 'dbg-gdb < ',line
							if @outputPanel
								if @showOutputPanelNext
									@showOutputPanelNext = false
									@outputPanel.show()
								@unseenOutputPanelContent = true
								@outputPanel.print line

			stderr: (data) =>
				if @outputPanel
					if @showOutputPanelNext
						@showOutputPanelNext = false
						@outputPanel.show()
					@unseenOutputPanelContent = true
					@outputPanel.print line for line in data.replace(/\r?\n$/,'').split(/\r?\n/)

			exit: (data) =>
				@miEmitter.emit 'exit'

		@process.emitter.on 'will-throw-error', (event) =>
			event.handle()

			error = event.error

			if error.code == 'ENOENT' && (error.syscall.indexOf 'spawn') == 0
				handleError "Could not find `#{command}`  \nPlease ensure it is correctly installed and available in your system PATH"
			else
				handleError error.message

		@processAwaiting = false
		@processQueued = []

	stop: ->
		# @cleanupFrame()
		@errorEncountered = null
		@variableObjects = {}
		@variableRootObjects = {}

		@process?.kill()
		@process = null
		@processAwaiting = false
		@processQueued = []

		if @interactiveSession
			@interactiveSession.discard()
			@interactiveSession = null

		setTimeout => # wait for any queued output to process, first
			if !@closedNaturally or !@unseenOutputPanelContent
				@outputPanel?.hide()
		, 0

	continue: ->
		@cleanupFrame().then =>
			@sendCommand '-exec-continue --all'
				.catch (error) =>
					if typeof error != 'string' then return
					@handleMiError error

	pause: ->
		@cleanupFrame().then =>
			@sendCommand '-exec-interrupt --all'
				.catch (error) =>
					if typeof error != 'string' then return
					@handleMiError error

	selectFrame: (index) ->
		@cleanupFrame().then =>
			reversedIndex = @stackList.length-1-index
			@frame = reversedIndex
			@ui.setFrame index
			@refreshFrame()

	getVariableChildren: (name) -> return new Promise (fulfill) =>
		seperator = name.lastIndexOf '.'
		if seperator >= 0
			variableName = @variableObjects[name.substr 0, seperator] + '.' + (name.substr seperator+1)
		else
			variableName = @variableObjects[name]

		@sendCommand '-var-list-children 1 '+variableName
			.then ({type, data}) =>
				children = []
				if data.children then for child in data.children
					@variableObjects[name+'.'+child.exp] = child.name

					children.push
						name: child.exp
						type: child.type
						value: prettyValue child.value
						expandable: child.numchild and parseInt(child.numchild) > 0

				fulfill children

			.catch (error) =>
				if typeof error != 'string' then return

				fulfill [
					name: ''
					type: ''
					value: error
					expandable: false
				]

	selectThread: (index) ->
		@cleanupFrame().then =>
			@thread = index
			@ui.setThread index
			@refreshFrame()

	refreshFrame: ->
		# @sendCommand '-stack-list-variables --thread '+@thread+' --frame '+@frame+' 2'
		# 	.then ({type, data}) =>
		# 		variables = []
		# 		if data.variables
		# 			for variable in data.variables
		# 				variables.push
		# 					name: variable.name
		# 					type: variable.type
		# 					value: variable.value
		# 		@ui.setVariables variables
		# 	.catch (error) =>
		# 	if typeof error != 'string' then return
		# 	@handleMiError error

		@sendCommand '-stack-list-variables --thread '+@thread+' --frame '+@frame+' 1'
			.then ({type, data}) =>
				variables = []
				pending = 0
				start = -> pending++
				stop = =>
					pending--
					if !pending
						@ui.setVariables variables

				start()
				if data.variables
					for variable in data.variables
						do (variable) =>
							start()
							@sendCommand '-var-create - * '+variable.name
								.then ({type, data}) =>
									@variableObjects[variable.name] = @variableRootObjects[variable.name] = data.name
									variables.push
										name: variable.name
										value: prettyValue variable.value
										type: data.type
										expandable: data.numchild and (parseInt data.numchild) > 0
									stop()

								.catch (error) =>
									if typeof error != 'string' then return
									if variable.value != '<optimized out>' then @handleMiError error
									variables.push
										name: variable.name
										value: variable.value
									stop()

				stop()

			.catch (error) =>
				if typeof error != 'string' then return
				@handleMiError error

	stepIn: ->
		@cleanupFrame().then =>
			@sendCommand '-exec-step'
				.catch (error) =>
					if typeof error != 'string' then return
					@handleMiError error

	stepOver: ->
		@cleanupFrame().then =>
			@sendCommand '-exec-next'
				.catch (error) =>
					if typeof error != 'string' then return
					@handleMiError error

	stepOut: ->
		@cleanupFrame().then =>
			@sendCommand '-exec-finish'
				.catch (error) =>
					if typeof error != 'string' then return
					@handleMiError error

	sendCommand: (command, logCallback) ->
		if @processAwaiting
			return new Promise (resolve, reject) =>
				@processQueued.push =>
					@sendCommand command
						.then resolve, reject

		@processAwaiting = true

		logListener = null
		if logCallback
			logListener = @miEmitter.on 'log', logCallback

		successEvent = null
		exitEvent = null
		promise = Promise.race [
			new Promise (resolve, reject) =>
				successEvent = @miEmitter.once 'result', ({type, data}) =>
					exitEvent.dispose()
					# "done", "running" (same as done), "connected", "error", "exit"
					# https://sourceware.org/gdb/onlinedocs/gdb/GDB_002fMI-Result-Records.html#GDB_002fMI-Result-Records
					if type=='error'
						reject data.msg||'Unknown GDB error'
					else
						resolve {type:type, data:data}
			,new Promise (resolve, reject) =>
				exitEvent = @miEmitter.once 'exit', =>
					successEvent.dispose()
					reject 'Debugger terminated'
		]

		promise.then =>
			logListener?.dispose()
			@processAwaiting = false
			if @processQueued.length > 0
				@processQueued.shift()()
		, (error) =>
			logListener?.dispose()
			@processAwaiting = false
			if typeof error != 'string'
				console.error error
			if @processQueued.length > 0
				@processQueued.shift()()

		if @logToConsole then console.log 'dbg-gdb > ',command
		@process.process.stdin.write command+'\r\n', binary: true
		return promise

	handleMiError: (error, title) ->
		atom.notifications.addError title||'Error received from GDB',
			description: 'GDB said:\n\n> '+error.trim().split(/\r?\n/).join('\n\n> ')
			dismissable: true

	addBreakpoint: (breakpoint) ->
		@breakpoints.push breakpoint
		@sendCommand '-break-insert -f '+(escapePath breakpoint.path)+':'+breakpoint.line, (log) =>
			if matched = log.match /no source file named (.*?)\.?$/i
				atom.notifications.addError 'Error inserting breakpoint',
					description: 'This file was not found within the current executable.  \nPlease ensure debug symbols for this file are included in the compiled executable.'
					dismissable: true

			else if log.match /no symbol table is loaded/i
				atom.notifications.addError 'Error inserting breakpoint',
					description: 'This program was not compiled with debug symbols.  \nBreakpoints cannot be used.'
					dismissable: true

	removeBreakpoint: (breakpoint) ->
		for i,compare in @breakpoints
			if compare==breakpoint
				@breakpoints.splice i,1

		@sendCommand '-break-list'
			.then ({type, data}) =>
				if data.BreakpointTable
					for entry in data.BreakpointTable.body
						if entry.fullname==breakpoint.path and parseInt(entry.line)==breakpoint.line
							@sendCommand '-break-delete '+entry.number
								.catch (error) =>
									if typeof error != 'string' then return
									@handleMiError error

	provideDbgProvider: ->
		name: 'dbg-gdb'
		description: 'GDB debugger'

		canHandleOptions: (options) =>
			return new Promise (fulfill, reject) =>
				@start options

				@sendCommand '-file-exec-and-symbols '+escapePath (path.resolve options.basedir||'', options.path)
					.then =>
						@stop()
						fulfill true

					.catch (error) =>
						@stop()
						if typeof error == 'string' && error.match /not in executable format/
							# Error was definitely the file. This is not-debuggable
							fulfill false
						else
							# Error was something else. Say "yes" for now, so that the user can begin the debug and see what it really is
							fulfill true

		debug: @debug.bind this
		stop: @stop.bind this

		continue: @continue.bind this
		pause: @pause.bind this

		selectFrame: @selectFrame.bind this
		getVariableChildren: @getVariableChildren.bind this

		stepIn: @stepIn.bind this
		stepOver: @stepOver.bind this
		stepOut: @stepOut.bind this

		addBreakpoint: @addBreakpoint.bind this
		removeBreakpoint: @removeBreakpoint.bind this

	consumeDbg: (dbg) ->
		@dbg = dbg
