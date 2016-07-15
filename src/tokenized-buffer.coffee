_ = require 'underscore-plus'
{CompositeDisposable, Emitter} = require 'event-kit'
{Point, Range} = require 'text-buffer'
{ScopeSelector} = require 'first-mate'
Model = require './model'
TokenizedLine = require './tokenized-line'
TokenIterator = require './token-iterator'
Token = require './token'
ScopeDescriptor = require './scope-descriptor'
TokenizedBufferIterator = require './tokenized-buffer-iterator'

module.exports =
class TokenizedBuffer extends Model
  grammar: null
  currentGrammarScore: null
  buffer: null
  tabLength: null
  tokenizedLines: null
  chunkSize: 50
  invalidRows: null
  visible: false
  changeCount: 0

  @deserialize: (state, atomEnvironment) ->
    if state.bufferId
      state.buffer = atomEnvironment.project.bufferForIdSync(state.bufferId)
    else
      # TODO: remove this fallback after everyone transitions to the latest version.
      state.buffer = atomEnvironment.project.bufferForPathSync(state.bufferPath)
    state.grammarRegistry = atomEnvironment.grammars
    state.assert = atomEnvironment.assert
    new this(state)

  constructor: (params) ->
    {
      @buffer, @tabLength, @largeFileMode,
      @grammarRegistry, @assert, grammarScopeName
    } = params

    @emitter = new Emitter
    @disposables = new CompositeDisposable
    @tokenIterator = new TokenIterator({@grammarRegistry})

    @disposables.add @buffer.preemptDidChange (e) => @handleBufferChange(e)
    @rootScopeDescriptor = new ScopeDescriptor(scopes: ['text.plain'])

    if grammar = @grammarRegistry.grammarForScopeName(grammarScopeName)
      @setGrammar(grammar)
    else
      @retokenizeLines()
      @grammarToRestoreScopeName = grammarScopeName

  destroyed: ->
    @disposables.dispose()

  buildIterator: ->
    new TokenizedBufferIterator(this, @grammarRegistry)

  getInvalidatedRanges: ->
    if @invalidatedRange?
      [@invalidatedRange]
    else
      []

  onDidInvalidateRange: (fn) ->
    @emitter.on 'did-invalidate-range', fn

  serialize: ->
    state = {
      deserializer: 'TokenizedBuffer'
      bufferPath: @buffer.getPath()
      bufferId: @buffer.getId()
      tabLength: @tabLength
      largeFileMode: @largeFileMode
    }
    state.grammarScopeName = @grammar?.scopeName unless @buffer.getPath()
    state

  observeGrammar: (callback) ->
    callback(@grammar)
    @onDidChangeGrammar(callback)

  onDidChangeGrammar: (callback) ->
    @emitter.on 'did-change-grammar', callback

  onDidChange: (callback) ->
    @emitter.on 'did-change', callback

  onDidTokenize: (callback) ->
    @emitter.on 'did-tokenize', callback

  setGrammar: (grammar, score) ->
    return unless grammar? and grammar isnt @grammar

    @grammar = grammar
    @rootScopeDescriptor = new ScopeDescriptor(scopes: [@grammar.scopeName])
    @currentGrammarScore = score ? @grammarRegistry.getGrammarScore(grammar, @buffer.getPath(), @getGrammarSelectionContent())

    @grammarToRestoreScopeName = null

    @grammarUpdateDisposable?.dispose()
    @grammarUpdateDisposable = @grammar.onDidUpdate => @retokenizeLines()
    @disposables.add(@grammarUpdateDisposable)

    @retokenizeLines()

    @emitter.emit 'did-change-grammar', grammar

  getGrammarSelectionContent: ->
    @buffer.getTextInRange([[0, 0], [10, 0]])

  hasTokenForSelector: (selector) ->
    for tokenizedLine in @tokenizedLines when tokenizedLine?
      for token in tokenizedLine.tokens
        return true if selector.matches(token.scopes)
    false

  retokenizeLines: ->
    lastRow = @buffer.getLastRow()
    @fullyTokenized = false
    @tokenizedLines = new Array(lastRow + 1)
    @invalidRows = []
    @invalidateRow(0)
    event = {start: 0, end: lastRow, delta: 0}
    @emitter.emit 'did-change', event

  setVisible: (@visible) ->
    @tokenizeInBackground() if @visible

  getTabLength: -> @tabLength

  setTabLength: (@tabLength) ->

  tokenizeInBackground: ->
    return if not @visible or @pendingChunk or not @isAlive()

    @pendingChunk = true
    _.defer =>
      @pendingChunk = false
      @tokenizeNextChunk() if @isAlive() and @buffer.isAlive()

  tokenizeNextChunk: ->
    # Short circuit null grammar which can just use the placeholder tokens
    if (not @grammar? or @grammar.name is 'Null grammar') and @firstInvalidRow()?
      @invalidRows = []
      @markTokenizationComplete()
      return

    rowsRemaining = @chunkSize

    while @firstInvalidRow()? and rowsRemaining > 0
      startRow = @invalidRows.shift()
      lastRow = @getLastRow()
      continue if startRow > lastRow

      row = startRow
      loop
        previousStack = @stackForRow(row)
        @tokenizedLines[row] = @buildTokenizedLineForRow(row, @stackForRow(row - 1), @openScopesForRow(row))
        if --rowsRemaining is 0
          filledRegion = false
          endRow = row
          break
        if row is lastRow or _.isEqual(@stackForRow(row), previousStack)
          filledRegion = true
          endRow = row
          break
        row++

      @validateRow(endRow)
      @invalidateRow(endRow + 1) unless filledRegion

      event = {start: startRow, end: endRow, delta: 0}
      @emitter.emit 'did-change', event
      @emitter.emit 'did-invalidate-range', Range(Point(startRow, 0), Point(endRow + 1, 0))

    if @firstInvalidRow()?
      @tokenizeInBackground()
    else
      @markTokenizationComplete()

  markTokenizationComplete: ->
    unless @fullyTokenized
      @emitter.emit 'did-tokenize'
    @fullyTokenized = true

  firstInvalidRow: ->
    @invalidRows[0]

  validateRow: (row) ->
    @invalidRows.shift() while @invalidRows[0] <= row
    return

  invalidateRow: (row) ->
    return if @largeFileMode

    @invalidRows.push(row)
    @invalidRows.sort (a, b) -> a - b
    @tokenizeInBackground()

  updateInvalidRows: (start, end, delta) ->
    @invalidRows = @invalidRows.map (row) ->
      if row < start
        row
      else if start <= row <= end
        end + delta + 1
      else if row > end
        row + delta

  handleBufferChange: (e) ->
    @changeCount = @buffer.changeCount

    {oldRange, newRange} = e
    start = oldRange.start.row
    end = oldRange.end.row
    delta = newRange.end.row - oldRange.end.row

    @updateInvalidRows(start, end, delta)
    previousEndStack = @stackForRow(end) # used in spill detection below
    if @largeFileMode
      newTokenizedLines = @buildPlaceholderTokenizedLinesForRows(start, end + delta)
    else
      newTokenizedLines = @buildTokenizedLinesForRows(start, end + delta, @stackForRow(start - 1), @openScopesForRow(start))
    _.spliceWithArray(@tokenizedLines, start, end - start + 1, newTokenizedLines)

    newEndStack = @stackForRow(end + delta)
    if newEndStack and not _.isEqual(newEndStack, previousEndStack)
      @invalidateRow(end + delta + 1)

    @invalidatedRange = Range(start, end)

    event = {start, end, delta, bufferChange: e}
    @emitter.emit 'did-change', event

  isFoldableAtRow: (row) ->
    if @largeFileMode
      false
    else
      @isFoldableCodeAtRow(row) or @isFoldableCommentAtRow(row)

  # Returns a {Boolean} indicating whether the given buffer row starts
  # a a foldable row range due to the code's indentation patterns.
  isFoldableCodeAtRow: (row) ->
    # Investigating an exception that's occurring here due to the line being
    # undefined. This should paper over the problem but we want to figure out
    # what is happening:
    tokenizedLine = @tokenizedLineForRow(row)
    @assert tokenizedLine?, "TokenizedLine is undefined", (error) =>
      error.metadata = {
        row: row
        rowCount: @tokenizedLines.length
        tokenizedBufferChangeCount: @changeCount
        bufferChangeCount: @buffer.changeCount
      }

    return false unless tokenizedLine?

    return false if @buffer.isRowBlank(row) or tokenizedLine.isComment()
    nextRow = @buffer.nextNonBlankRow(row)
    return false unless nextRow?

    @indentLevelForRow(nextRow) > @indentLevelForRow(row)

  isFoldableCommentAtRow: (row) ->
    previousRow = row - 1
    nextRow = row + 1
    return false if nextRow > @buffer.getLastRow()

    (row is 0 or not @tokenizedLineForRow(previousRow).isComment()) and
      @tokenizedLineForRow(row).isComment() and
      @tokenizedLineForRow(nextRow).isComment()

  buildTokenizedLinesForRows: (startRow, endRow, startingStack, startingopenScopes) ->
    ruleStack = startingStack
    openScopes = startingopenScopes
    stopTokenizingAt = startRow + @chunkSize
    tokenizedLines = for row in [startRow..endRow]
      if (ruleStack or row is 0) and row < stopTokenizingAt
        tokenizedLine = @buildTokenizedLineForRow(row, ruleStack, openScopes)
        ruleStack = tokenizedLine.ruleStack
        openScopes = @scopesFromTags(openScopes, tokenizedLine.tags)
      else
        tokenizedLine = @buildPlaceholderTokenizedLineForRow(row, openScopes)
      tokenizedLine

    if endRow >= stopTokenizingAt
      @invalidateRow(stopTokenizingAt)
      @tokenizeInBackground()

    tokenizedLines

  buildPlaceholderTokenizedLinesForRows: (startRow, endRow) ->
    @buildPlaceholderTokenizedLineForRow(row) for row in [startRow..endRow] by 1

  buildPlaceholderTokenizedLineForRow: (row) ->
    openScopes = []
    text = @buffer.lineForRow(row)
    tags = [text.length]
    lineEnding = @buffer.lineEndingForRow(row)
    new TokenizedLine({openScopes, text, tags, lineEnding, @tokenIterator})

  buildTokenizedLineForRow: (row, ruleStack, openScopes) ->
    @buildTokenizedLineForRowWithText(row, @buffer.lineForRow(row), ruleStack, openScopes)

  buildTokenizedLineForRowWithText: (row, text, ruleStack = @stackForRow(row - 1), openScopes = @openScopesForRow(row)) ->
    lineEnding = @buffer.lineEndingForRow(row)
    {tags, ruleStack} = @grammar.tokenizeLine(text, ruleStack, row is 0, false)
    new TokenizedLine({openScopes, text, tags, ruleStack, lineEnding, @tokenIterator})

  tokenizedLineForRow: (bufferRow) ->
    if 0 <= bufferRow < @tokenizedLines.length
      @tokenizedLines[bufferRow] ?= @buildPlaceholderTokenizedLineForRow(bufferRow)

  tokenizedLinesForRows: (startRow, endRow) ->
    for row in [startRow..endRow] by 1
      @tokenizedLineForRow(row)

  stackForRow: (bufferRow) ->
    @tokenizedLines[bufferRow]?.ruleStack

  openScopesForRow: (bufferRow) ->
    if bufferRow > 0
      precedingLine = @tokenizedLineForRow(bufferRow - 1)
      @scopesFromTags(precedingLine.openScopes, precedingLine.tags)
    else
      []

  scopesFromTags: (startingScopes, tags) ->
    scopes = startingScopes.slice()
    for tag in tags when tag < 0
      if (tag % 2) is -1
        scopes.push(tag)
      else
        matchingStartTag = tag + 1
        loop
          break if scopes.pop() is matchingStartTag
          if scopes.length is 0
            @assert false, "Encountered an unmatched scope end tag.", (error) =>
              error.metadata = {
                grammarScopeName: @grammar.scopeName
                unmatchedEndTag: @grammar.scopeForId(tag)
              }
              path = require 'path'
              error.privateMetadataDescription = "The contents of `#{path.basename(@buffer.getPath())}`"
              error.privateMetadata = {
                filePath: @buffer.getPath()
                fileContents: @buffer.getText()
              }
            break
    scopes

  indentLevelForRow: (bufferRow) ->
    line = @buffer.lineForRow(bufferRow)
    indentLevel = 0

    if line is ''
      nextRow = bufferRow + 1
      lineCount = @getLineCount()
      while nextRow < lineCount
        nextLine = @buffer.lineForRow(nextRow)
        unless nextLine is ''
          indentLevel = Math.ceil(@indentLevelForLine(nextLine))
          break
        nextRow++

      previousRow = bufferRow - 1
      while previousRow >= 0
        previousLine = @buffer.lineForRow(previousRow)
        unless previousLine is ''
          indentLevel = Math.max(Math.ceil(@indentLevelForLine(previousLine)), indentLevel)
          break
        previousRow--

      indentLevel
    else
      @indentLevelForLine(line)

  indentLevelForLine: (line) ->
    if match = line.match(/^[\t ]+/)
      indentLength = 0
      for character in match[0]
        if character is '\t'
          indentLength += @getTabLength() - (indentLength % @getTabLength())
        else
          indentLength++

      indentLength / @getTabLength()
    else
      0

  scopeDescriptorForPosition: (position) ->
    {row, column} = @buffer.clipPosition(Point.fromObject(position))

    iterator = @tokenizedLineForRow(row).getTokenIterator()
    while iterator.next()
      if iterator.getBufferEnd() > column
        scopes = iterator.getScopes()
        break

    # rebuild scope of last token if we iterated off the end
    unless scopes?
      scopes = iterator.getScopes()
      scopes.push(iterator.getScopeEnds().reverse()...)

    new ScopeDescriptor({scopes})

  tokenForPosition: (position) ->
    {row, column} = Point.fromObject(position)
    @tokenizedLineForRow(row).tokenAtBufferColumn(column)

  tokenStartPositionForPosition: (position) ->
    {row, column} = Point.fromObject(position)
    column = @tokenizedLineForRow(row).tokenStartColumnForBufferColumn(column)
    new Point(row, column)

  bufferRangeForScopeAtPosition: (selector, position) ->
    position = Point.fromObject(position)

    {openScopes, tags} = @tokenizedLineForRow(position.row)
    scopes = openScopes.map (tag) => @grammar.scopeForId(tag)

    startColumn = 0
    for tag, tokenIndex in tags
      if tag < 0
        if tag % 2 is -1
          scopes.push(@grammar.scopeForId(tag))
        else
          scopes.pop()
      else
        endColumn = startColumn + tag
        if endColumn >= position.column
          break
        else
          startColumn = endColumn


    return unless selectorMatchesAnyScope(selector, scopes)

    startScopes = scopes.slice()
    for startTokenIndex in [(tokenIndex - 1)..0] by -1
      tag = tags[startTokenIndex]
      if tag < 0
        if tag % 2 is -1
          startScopes.pop()
        else
          startScopes.push(@grammar.scopeForId(tag))
      else
        break unless selectorMatchesAnyScope(selector, startScopes)
        startColumn -= tag

    endScopes = scopes.slice()
    for endTokenIndex in [(tokenIndex + 1)...tags.length] by 1
      tag = tags[endTokenIndex]
      if tag < 0
        if tag % 2 is -1
          endScopes.push(@grammar.scopeForId(tag))
        else
          endScopes.pop()
      else
        break unless selectorMatchesAnyScope(selector, endScopes)
        endColumn += tag

    new Range(new Point(position.row, startColumn), new Point(position.row, endColumn))

  # Gets the row number of the last line.
  #
  # Returns a {Number}.
  getLastRow: ->
    @buffer.getLastRow()

  getLineCount: ->
    @buffer.getLineCount()

  logLines: (start=0, end=@buffer.getLastRow()) ->
    for row in [start..end]
      line = @tokenizedLineForRow(row).text
      console.log row, line, line.length
    return

selectorMatchesAnyScope = (selector, scopes) ->
  targetClasses = selector.replace(/^\./, '').split('.')
  _.any scopes, (scope) ->
    scopeClasses = scope.split('.')
    _.isSubset(targetClasses, scopeClasses)
