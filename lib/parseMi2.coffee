module.exports = (source) ->
	position = 0

	readSymbol = (symbol) ->
		if position<source.length and (source.charAt position)==symbol
			position++
			return true
		else
			return false

	readWord = ->
		if position >= source.length then return false
		if /[\[\]{}=,]/.test source[position] then return false
		seperator = source.indexOf '=', position
		if seperator>=0
			if seperator==position then return false
			result = source.substr position, seperator - position
			position = seperator
			return result
		else
			result = source.substr position
			position = source.length
			return result

	readString = ->
		if !readSymbol '"' then return false
		start = position
		string = ''
		while position<source.length
			char = source.charAt position
			if char=='\\'
				position++
				switch char=source.charAt position
					when 't' then string += '\t'
					when 'r' then string += '\r'
					when 'n' then string += '\n'
					#TODO:octal and hex sequences?
					else string += char
			else if char=='"'
				position++
				return string
			else
				string += char
			position++
		position = start
		return false

	readTuple = ->
		if !readSymbol '{' then return false
		start = position
		contents = readObjectContents()
		if !readSymbol '}'
			position = start
			return false
		return contents

	readList = ->
		if !readSymbol '[' then return false
		start = position
		values = []
		while (value = readValueOrPair()) != false
			values.push value
			if !readSymbol ',' then break
		if !readSymbol ']'
			position = start
			return false
		return values

	readValueOrPair = ->
		value = readValue()
		if value==false
			value = readPair()
			if value!=false then value = value.value
		return value

	readValue = ->
		if position >= source.length then return false
		value = readString()
		if value!=false then return value
		value = readTuple()
		if value!=false then return value
		value = readList()
		if value!=false then return value
		return false

	readPair = ->
		if position >= source.length then return false
		name = readWord()
		if name==false then return false
		if !readSymbol '=' then return false
		value = readValue()
		if value==false then return false
		return {name:name, value:value}

	readObjectContents = ->
		result = {}
		pair = null

		nameless = readString()
		if nameless!=false
			result._ = nameless
			if !readSymbol ',' then return result

		while true
			if (pair = readPair())==false then break
			result[pair.name] = pair.value
			if !readSymbol ',' then break
		return result

	return readObjectContents();
