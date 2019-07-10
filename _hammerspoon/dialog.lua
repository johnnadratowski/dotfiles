function getInput(whatMessage, whatErrorMessage, defaultAnswer)
  local appleScriptA = 'set whatMessage to "' .. whatMessage .. '"' .. "\n\n"
  local appleScriptB = 'set whatErrorMessage to "' .. whatErrorMessage .. '"' .. "\n\n"
  local appleScriptC = 'set defaultAnswer to "' .. defaultAnswer .. '"' .. "\n\n"
  local appleScriptD =
    [[
		set allowedLetters to characters of (do shell script "printf \"%c\" {a..z}")
		set allowedNumbers to characters of (do shell script "printf \"%c\" {0..9}")
		set allowedAll to allowedLetters & allowedNumbers & space

		repeat
			try
				tell me to activate
				set response to text returned of (display dialog whatMessage default answer defaultAnswer buttons {"OK", "Cancel"} default button 1 with icon Note)
			on error
				-- Cancel Pressed:
				return false
			end try
			try
				set invalidCharacters to false
				repeat with aCharacter in response
					if (aCharacter as text) is not in allowedAll then
						set invalidCharacters to true
					end if
				end repeat
				if length of response is 0 then
					set invalidCharacters to true
				end if
				if invalidCharacters is false then
					exit repeat
				end
			end try
			display dialog whatErrorMessage buttons {"OK"} with icon fcpxIcon
		end repeat
		return response
	]]
  a, result = hs.osascript.applescript(appleScriptA .. appleScriptB .. appleScriptC .. appleScriptD)
  return result
end

return getInput
