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
	miEmitter: null

	activate: (state) ->
		require('atom-package-deps').install('dbg-gdb');

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
			@outputPanel?.print line

		@miEmitter.on 'result', ({type, data}) =>
			switch type
				when 'running'
					@ui.running()

		@miEmitter.on 'exec', ({type, data}) =>
			switch type
				when 'running'
					@ui.running()

				when 'stopped'

					switch data.reason
						when 'exited-normally'
							@ui.stop()
							return

						when 'signal-received'
							if data['signal-name'] != 'SIGINT'
								@errorEncountered = data['signal-meaning'] or if data['signal-name'] then data['signal-name']+'signal received' else 'Signal received'
								@ui.showError @errorEncountered

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

		@sendCommand '-file-exec-and-symbols '+escapePath (path.resolve options.basedir||'', options.path)
			.then =>
				begin = () =>
					for breakpoint in @breakpoints
						@sendCommand '-break-insert '+(escapePath breakpoint.path)+':'+breakpoint.line

					@sendCommand 'set environment ' + env_var for env_var in options.env_vars if options.env_vars?

					@sendCommand command for command in [].concat options.gdb_commands||[]
					
					@sendCommand '-exec-arguments ' + options.args.join(" ") if options.args?
					@sendCommand '-exec-run'
						.catch (error) =>
							if typeof error != 'string' then return
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

			.catch (error) =>
				if typeof error != 'string' then return
				if error.match /not in executable format/
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
		outputRevealed = @outputPanel?.isVisible();

		matchAsyncHeader = /^([\^=*+])(.+?)(?:,(.*))?$/
		matchStreamHeader = /^([~@&])(.*)?$/

		@miEmitter = new Emitter()
		@process = new BufferedProcess
			command: options.gdb_executable||'gdb'
			args: ['-quiet','--interpreter=mi2'].concat options.gdb_arguments||[]
			options:
				cwd: (path.resolve options.basedir||'', options.cwd||'')
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
							when '~' then @miEmitter.emit 'console', data
					else
						if line!='(gdb)' and line!='(gdb) '
							if @logToConsole then console.log 'dbg-gdb < ',line
							if @outputPanel
								if !outputRevealed
									outputRevealed = true
									@outputPanel.show()
								@outputPanel.print line

			stderr: (data) =>
				if @outputPanel
					if !outputRevealed
						outputRevealed = true
						@outputPanel.show()
					@outputPanel.print line for line in data.replace(/\r?\n$/,'').split(/\r?\n/)

			exit: (data) =>
				@miEmitter.emit 'exit'

		@processAwaiting = false
		@processQueued = []

	stop: ->
		# @cleanupFrame()
		@errorEncountered = null
		@variableObjects = {}
		@variableRootObjects = {}

		@process?.kill();
		@process = null
		@processAwaiting = false
		@processQueued = []

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
									@handleMiError error
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

	sendCommand: (command) ->
		if @processAwaiting
			return new Promise (resolve, reject) =>
				@processQueued.push =>
					@sendCommand command
						.then resolve, reject

		@processAwaiting = true
		promise = Promise.race [
			new Promise (resolve, reject) =>
				event = @miEmitter.on 'result', ({type, data}) =>
					event.dispose()
					# "done", "running" (same as done), "connected", "error", "exit"
					# https://sourceware.org/gdb/onlinedocs/gdb/GDB_002fMI-Result-Records.html#GDB_002fMI-Result-Records
					if type=='error'
						reject data.msg||'Unknown GDB error'
					else
						resolve {type:type, data:data}
			,new Promise (resolve, reject) =>
				event = @miEmitter.on 'exit', =>
					event.dispose()
					reject 'Debugger terminated'
		]
		promise.then =>
			@processAwaiting = false
			if @processQueued.length > 0
				@processQueued.shift()()
		, (error) =>
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
		@sendCommand '-break-insert '+(escapePath breakpoint.path)+':'+breakpoint.line

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
