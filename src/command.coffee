# The `coffee` utility. Handles command-line compilation of CoffeeScript
# into various forms: saved into `.js` files or printed to stdout
# or recompiled every time the source is saved,
# printed as a token stream or as the syntax tree, or launch an
# interactive REPL.

# External dependencies.
fs             = require 'fs'
path           = require 'path'
helpers        = require './helpers'
optparse       = require './optparse'
CoffeeScript   = require './'
{spawn, exec}  = require 'child_process'
{EventEmitter} = require 'events'

useWinPathSep  = path.sep is '\\'

# Allow CoffeeScript to emit Node.js events.
helpers.extend CoffeeScript, new EventEmitter

printLine = (line) -> process.stdout.write line + '\n'
printWarn = (line) -> process.stderr.write line + '\n'

hidden = (file) -> /^\.|~$/.test file

# The help banner that is printed in conjunction with `-h`/`--help`.
BANNER = '''
  Usage: coffee [options] path/to/script.coffee [args]

  If called without options, `coffee` will run your script.
'''

# The list of all the valid option flags that `coffee` knows how to handle.
SWITCHES = [
  ['-b', '--bare',              'compile without a top-level function wrapper']
  ['-c', '--compile',           'compile to JavaScript and save as .js files']
  ['-e', '--eval',              'pass a string from the command line as input']
  ['-h', '--help',              'display this help message']
  ['-i', '--interactive',       'run an interactive CoffeeScript REPL']
  ['-j', '--join [FILE]',       'concatenate the source CoffeeScript before compiling']
  ['-m', '--map',               'generate source map and save as .js.map files']
  ['-M', '--inline-map',        'generate source map and include it directly in output']
  ['-n', '--nodes',             'print out the parse tree that the parser produces']
  [      '--nodejs [ARGS]',     'pass options directly to the "node" binary']
  [      '--no-header',         'suppress the "Generated by" header']
  ['-o', '--output [PATH]',     'set the output path or path/filename for compiled JavaScript']
  ['-p', '--print',             'print out the compiled JavaScript']
  ['-r', '--require [MODULE*]', 'require the given module before eval or REPL']
  ['-s', '--stdio',             'listen for and compile scripts over stdio']
  ['-l', '--literate',          'treat stdio as literate style coffeescript']
  ['-t', '--transpile',         'pipe generated JavaScript through Babel']
  [      '--tokens',            'print out the tokens that the lexer/rewriter produce']
  ['-v', '--version',           'display the version number']
  ['-w', '--watch',             'watch scripts for changes and rerun commands']
]

# Top-level objects shared by all the functions.
opts         = {}
sources      = []
sourceCode   = []
notSources   = {}
watchedDirs  = {}
optionParser = null

exports.buildCSOptionParser = buildCSOptionParser = ->
  new optparse.OptionParser SWITCHES, BANNER

# Run `coffee` by parsing passed options and determining what action to take.
# Many flags cause us to divert before compiling anything. Flags passed after
# `--` will be passed verbatim to your script as arguments in `process.argv`
exports.run = ->
  optionParser = buildCSOptionParser()
  try parseOptions()
  catch err
    console.error "option parsing error: #{err.message}"
    process.exit 1

  if (not opts.doubleDashed) and (opts.arguments[1] is '--')
    printWarn '''
      coffee was invoked with '--' as the second positional argument, which is
      now deprecated. To pass '--' as an argument to a script to run, put an
      additional '--' before the path to your script.

      '--' will be removed from the argument list.
    '''
    printWarn "The positional arguments were: #{JSON.stringify opts.arguments}"
    opts.arguments = [opts.arguments[0]].concat opts.arguments[2..]

  # Make the REPL *CLI* use the global context so as to (a) be consistent with the
  # `node` REPL CLI and, therefore, (b) make packages that modify native prototypes
  # (such as 'colors' and 'sugar') work as expected.
  replCliOpts = useGlobal: yes
  opts.prelude = makePrelude opts.require       if opts.require
  replCliOpts.prelude = opts.prelude
  replCliOpts.transpile = opts.transpile
  return forkNode()                             if opts.nodejs
  return usage()                                if opts.help
  return version()                              if opts.version
  return require('./repl').start(replCliOpts)   if opts.interactive
  return compileStdio()                         if opts.stdio
  return compileScript null, opts.arguments[0]  if opts.eval
  return require('./repl').start(replCliOpts)   unless opts.arguments.length
  literals = if opts.run then opts.arguments.splice 1 else []
  process.argv = process.argv[0..1].concat literals
  process.argv[0] = 'coffee'

  if opts.output
    outputBasename = path.basename opts.output
    if '.' in outputBasename and
       outputBasename not in ['.', '..'] and
       not helpers.ends(opts.output, path.sep)
      # An output filename was specified, e.g. `/dist/scripts.js`.
      opts.outputFilename = outputBasename
      opts.outputPath = path.resolve path.dirname opts.output
    else
      # An output path was specified, e.g. `/dist`.
      opts.outputFilename = null
      opts.outputPath = path.resolve opts.output

  if opts.join
    opts.join = path.resolve opts.join
    console.error '''

    The --join option is deprecated and will be removed in a future version.

    If for some reason it's necessary to share local variables between files,
    replace...

        $ coffee --compile --join bundle.js -- a.coffee b.coffee c.coffee

    with...

        $ cat a.coffee b.coffee c.coffee | coffee --compile --stdio > bundle.js

    '''
  for source in opts.arguments
    source = path.resolve source
    compilePath source, yes, source

makePrelude = (requires) ->
  requires.map (module) ->
    [full, name, module] = match if match = module.match(/^(.*)=(.*)$/)
    name or= helpers.baseFileName module, yes, useWinPathSep
    "global['#{name}'] = require('#{module}')"
  .join ';'

# Compile a path, which could be a script or a directory. If a directory
# is passed, recursively compile all '.coffee', '.litcoffee', and '.coffee.md'
# extension source files in it and all subdirectories.
compilePath = (source, topLevel, base) ->
  return if source in sources   or
            watchedDirs[source] or
            not topLevel and (notSources[source] or hidden source)
  try
    stats = fs.statSync source
  catch err
    if err.code is 'ENOENT'
      console.error "File not found: #{source}"
      process.exit 1
    throw err
  if stats.isDirectory()
    if path.basename(source) is 'node_modules'
      notSources[source] = yes
      return
    if opts.run
      compilePath findDirectoryIndex(source), topLevel, base
      return
    watchDir source, base if opts.watch
    try
      files = fs.readdirSync source
    catch err
      if err.code is 'ENOENT' then return else throw err
    for file in files
      compilePath (path.join source, file), no, base
  else if topLevel or helpers.isCoffee source
    sources.push source
    sourceCode.push null
    delete notSources[source]
    watch source, base if opts.watch
    try
      code = fs.readFileSync source
    catch err
      if err.code is 'ENOENT' then return else throw err
    compileScript source, code.toString(), base
  else
    notSources[source] = yes

findDirectoryIndex = (source) ->
  for ext in CoffeeScript.FILE_EXTENSIONS
    index = path.join source, "index#{ext}"
    try
      return index if (fs.statSync index).isFile()
    catch err
      throw err unless err.code is 'ENOENT'
  console.error "Missing index.coffee or index.litcoffee in #{source}"
  process.exit 1

# Compile a single source script, containing the given code, according to the
# requested options. If evaluating the script directly, set `__filename`,
# `__dirname` and `module.filename` to be correct relative to the script's path.
compileScript = (file, input, base = null) ->
  options = compileOptions file, base
  try
    task = {file, input, options}
    CoffeeScript.emit 'compile', task
    if opts.tokens
      printTokens CoffeeScript.tokens task.input, task.options
    else if opts.nodes
      printLine CoffeeScript.nodes(task.input, task.options).toString().trim()
    else if opts.run
      CoffeeScript.register()
      CoffeeScript.eval opts.prelude, task.options if opts.prelude
      CoffeeScript.run task.input, task.options
    else if opts.join and task.file isnt opts.join
      task.input = helpers.invertLiterate task.input if helpers.isLiterate file
      sourceCode[sources.indexOf(task.file)] = task.input
      compileJoin()
    else
      compiled = CoffeeScript.compile task.input, task.options
      task.output = compiled
      if opts.map
        task.output = compiled.js
        task.sourceMap = compiled.v3SourceMap

      CoffeeScript.emit 'success', task
      if opts.print
        printLine task.output.trim()
      else if opts.compile or opts.map
        saveTo = if opts.outputFilename and sources.length is 1
          path.join opts.outputPath, opts.outputFilename
        else
          options.jsPath
        writeJs base, task.file, task.output, saveTo, task.sourceMap
  catch err
    CoffeeScript.emit 'failure', err, task
    return if CoffeeScript.listeners('failure').length
    message = err?.stack or "#{err}"
    if opts.watch
      printLine message + '\x07'
    else
      printWarn message
      process.exit 1

# Attach the appropriate listeners to compile scripts incoming over **stdin**,
# and write them back to **stdout**.
compileStdio = ->
  if opts.map
    console.error '--stdio and --map cannot be used together'
    process.exit 1
  buffers = []
  stdin = process.openStdin()
  stdin.on 'data', (buffer) ->
    buffers.push buffer if buffer
  stdin.on 'end', ->
    compileScript null, Buffer.concat(buffers).toString()

# If all of the source files are done being read, concatenate and compile
# them together.
joinTimeout = null
compileJoin = ->
  return unless opts.join
  unless sourceCode.some((code) -> code is null)
    clearTimeout joinTimeout
    joinTimeout = wait 100, ->
      compileScript opts.join, sourceCode.join('\n'), opts.join

# Watch a source CoffeeScript file using `fs.watch`, recompiling it every
# time the file is updated. May be used in combination with other options,
# such as `--print`.
watch = (source, base) ->
  watcher        = null
  prevStats      = null
  compileTimeout = null

  watchErr = (err) ->
    throw err unless err.code is 'ENOENT'
    return unless source in sources
    try
      rewatch()
      compile()
    catch
      removeSource source, base
      compileJoin()

  compile = ->
    clearTimeout compileTimeout
    compileTimeout = wait 25, ->
      fs.stat source, (err, stats) ->
        return watchErr err if err
        return rewatch() if prevStats and
                            stats.size is prevStats.size and
                            stats.mtime.getTime() is prevStats.mtime.getTime()
        prevStats = stats
        fs.readFile source, (err, code) ->
          return watchErr err if err
          compileScript(source, code.toString(), base)
          rewatch()

  startWatcher = ->
    watcher = fs.watch source
    .on 'change', compile
    .on 'error', (err) ->
      throw err unless err.code is 'EPERM'
      removeSource source, base

  rewatch = ->
    watcher?.close()
    startWatcher()

  try
    startWatcher()
  catch err
    watchErr err

# Watch a directory of files for new additions.
watchDir = (source, base) ->
  watcher        = null
  readdirTimeout = null

  startWatcher = ->
    watcher = fs.watch source
    .on 'error', (err) ->
      throw err unless err.code is 'EPERM'
      stopWatcher()
    .on 'change', ->
      clearTimeout readdirTimeout
      readdirTimeout = wait 25, ->
        try
          files = fs.readdirSync source
        catch err
          throw err unless err.code is 'ENOENT'
          return stopWatcher()
        for file in files
          compilePath (path.join source, file), no, base

  stopWatcher = ->
    watcher.close()
    removeSourceDir source, base

  watchedDirs[source] = yes
  try
    startWatcher()
  catch err
    throw err unless err.code is 'ENOENT'

removeSourceDir = (source, base) ->
  delete watchedDirs[source]
  sourcesChanged = no
  for file in sources when source is path.dirname file
    removeSource file, base
    sourcesChanged = yes
  compileJoin() if sourcesChanged

# Remove a file from our source list, and source code cache. Optionally remove
# the compiled JS version as well.
removeSource = (source, base) ->
  index = sources.indexOf source
  sources.splice index, 1
  sourceCode.splice index, 1
  unless opts.join
    silentUnlink outputPath source, base
    silentUnlink outputPath source, base, '.js.map'
    timeLog "removed #{source}"

silentUnlink = (path) ->
  try
    fs.unlinkSync path
  catch err
    throw err unless err.code in ['ENOENT', 'EPERM']

# Get the corresponding output JavaScript path for a source file.
outputPath = (source, base, extension=".js") ->
  basename  = helpers.baseFileName source, yes, useWinPathSep
  srcDir    = path.dirname source
  dir = unless opts.outputPath
    srcDir
  else if source is base
    opts.outputPath
  else
    path.join opts.outputPath, path.relative base, srcDir
  path.join dir, basename + extension

# Recursively mkdir, like `mkdir -p`.
mkdirp = (dir, fn) ->
  mode = 0o777 & ~process.umask()

  do mkdirs = (p = dir, fn) ->
    fs.exists p, (exists) ->
      if exists
        fn()
      else
        mkdirs path.dirname(p), ->
          fs.mkdir p, mode, (err) ->
            return fn err if err
            fn()

# Write out a JavaScript source file with the compiled code. By default, files
# are written out in `cwd` as `.js` files with the same name, but the output
# directory can be customized with `--output`.
#
# If `generatedSourceMap` is provided, this will write a `.js.map` file into the
# same directory as the `.js` file.
writeJs = (base, sourcePath, js, jsPath, generatedSourceMap = null) ->
  sourceMapPath = "#{jsPath}.map"
  jsDir  = path.dirname jsPath
  compile = ->
    if opts.compile
      js = ' ' if js.length <= 0
      if generatedSourceMap then js = "#{js}\n//# sourceMappingURL=#{helpers.baseFileName sourceMapPath, no, useWinPathSep}\n"
      fs.writeFile jsPath, js, (err) ->
        if err
          printLine err.message
          process.exit 1
        else if opts.compile and opts.watch
          timeLog "compiled #{sourcePath}"
    if generatedSourceMap
      fs.writeFile sourceMapPath, generatedSourceMap, (err) ->
        if err
          printLine "Could not write source map: #{err.message}"
          process.exit 1
  fs.exists jsDir, (itExists) ->
    if itExists then compile() else mkdirp jsDir, compile

# Convenience for cleaner setTimeouts.
wait = (milliseconds, func) -> setTimeout func, milliseconds

# When watching scripts, it's useful to log changes with the timestamp.
timeLog = (message) ->
  console.log "#{(new Date).toLocaleTimeString()} - #{message}"

# Pretty-print a stream of tokens, sans location data.
printTokens = (tokens) ->
  strings = for token in tokens
    tag = token[0]
    value = token[1].toString().replace(/\n/, '\\n')
    "[#{tag} #{value}]"
  printLine strings.join(' ')

# Use the [OptionParser module](optparse.html) to extract all options from
# `process.argv` that are specified in `SWITCHES`.
parseOptions = ->
  o = opts      = optionParser.parse process.argv[2..]
  o.compile     or=  !!o.output
  o.run         = not (o.compile or o.print or o.map)
  o.print       = !!  (o.print or (o.eval or o.stdio and o.compile))

# The compile-time options to pass to the CoffeeScript compiler.
compileOptions = (filename, base) ->
  if opts.transpile
    # The user has requested that the CoffeeScript compiler also transpile
    # via Babel. We don’t include Babel as a dependency because we want to
    # avoid dependencies in general, and most users probably won’t be relying
    # on us to transpile for them; we assume most users will probably either
    # run CoffeeScript’s output without transpilation (modern Node or evergreen
    # browsers) or use a proper build chain like Gulp or Webpack.
    try
      require 'babel-core'
    catch
      # Give appropriate instructions depending on whether `coffee` was run
      # locally or globally.
      if require.resolve('.').indexOf(process.cwd()) is 0
        console.error '''
          To use --transpile, you must have babel-core installed:
            npm install --save-dev babel-core
          And you must save options to configure Babel in one of the places it looks to find its options.
          See https://coffeescript.org/#transpilation
        '''
      else
        console.error '''
          To use --transpile with globally-installed CoffeeScript, you must have babel-core installed globally:
            npm install --global babel-core
          And you must save options to configure Babel in one of the places it looks to find its options, relative to the file being compiled or to the current folder.
          See https://coffeescript.org/#transpilation
        '''
      process.exit 1

    opts.transpile = {} unless typeof opts.transpile is 'object'

    # Pass a reference to Babel into the compiler, so that the transpile option
    # is available for the CLI. We need to do this so that tools like Webpack
    # can `require('coffeescript')` and build correctly, without trying to
    # require Babel.
    opts.transpile.transpile = CoffeeScript.transpile

    # Babel searches for its options (a `.babelrc` file, a `.babelrc.js` file,
    # a `package.json` file with a `babel` key, etc.) relative to the path
    # given to it in its `filename` option. Make sure we have a path to pass
    # along.
    unless opts.transpile.filename
      opts.transpile.filename = filename or path.resolve(base or process.cwd(), '<anonymous>')
  else
    opts.transpile = no

  answer =
    filename: filename
    literate: opts.literate or helpers.isLiterate(filename)
    bare: opts.bare
    header: opts.compile and not opts['no-header']
    transpile: opts.transpile
    sourceMap: opts.map
    inlineMap: opts['inline-map']

  if filename
    if base
      cwd = process.cwd()
      jsPath = outputPath filename, base
      jsDir = path.dirname jsPath
      answer = helpers.merge answer, {
        jsPath
        sourceRoot: path.relative jsDir, cwd
        sourceFiles: [path.relative cwd, filename]
        generatedFile: helpers.baseFileName(jsPath, no, useWinPathSep)
      }
    else
      answer = helpers.merge answer,
        sourceRoot: ""
        sourceFiles: [helpers.baseFileName filename, no, useWinPathSep]
        generatedFile: helpers.baseFileName(filename, yes, useWinPathSep) + ".js"
  answer

# Start up a new Node.js instance with the arguments in `--nodejs` passed to
# the `node` binary, preserving the other options.
forkNode = ->
  nodeArgs = opts.nodejs.split /\s+/
  args     = process.argv[1..]
  args.splice args.indexOf('--nodejs'), 2
  p = spawn process.execPath, nodeArgs.concat(args),
    cwd:        process.cwd()
    env:        process.env
    stdio:      [0, 1, 2]
  for signal in ['SIGINT', 'SIGTERM']
    process.on signal, do (signal) ->
      -> p.kill signal
  p.on 'exit', (code) -> process.exit code

# Print the `--help` usage message and exit. Deprecated switches are not
# shown.
usage = ->
  printLine optionParser.help()

# Print the `--version` message and exit.
version = ->
  printLine "CoffeeScript version #{CoffeeScript.VERSION}"
