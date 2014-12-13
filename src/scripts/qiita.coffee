# Description:
#   Create
#
# Commands:
#   hubot qiita authenticate me - Authenticate with Qiita account
#   hubot qiita new coediting item with template <template id> title <title>
#   hubot qiita new item with template <template id> "<title>"
#   hubot qiita list templates
#   hubot qiita list stocked items
#   hubot qiita start recording "<title>" - Start recording chat room
#   hubot qiita stop recording
#
# Configuration:
#   HUBOT_QIITA_TEAM
#   HUBOT_QIITA_CLIENT_ID (required)
#   HUBOT_QIITA_CLIENT_SECRET (required)

crypto = require 'crypto'
qs = require 'querystring'
dateformat = require 'dateformat'
{TextListener} = require 'hubot/src/listener'

BRAIN_KEY_ACCESS_TOKENS = 'qiita.access_tokens'
BRAIN_KEY_PENDING_TOKEN = 'qiita.pending_tokens'

module.exports = (robot) ->
  { HUBOT_QIITA_TEAM, HUBOT_QIITA_CLIENT_ID, HUBOT_QIITA_CLIENT_SECRET } = process.env

  missings = []
  'HUBOT_QIITA_TEAM HUBOT_QIITA_CLIENT_ID HUBOT_QIITA_CLIENT_SECRET'.split(/\s+/g).forEach (key)->
    missings.push key unless process.env[key]?
  if missings.length > 0
    robot.logger.error "Required configuration#{ if missings.length == 1 then 'is' else 's are' } missing: #{ missings.join ', ' }"

  scope = 'read_qiita_team write_qiita_team read_qiita write_qiita'

  removeListenr = (listener) ->
    index = robot.listeners.indexOf listener
    robot.listeners.splice index, 1 if index != -1

  waitForResponse = (waitMsg, callback) ->
    userId = waitMsg.envelope.user.id
    room = waitMsg.envelope.room
    listener = new TextListener robot, /.*/, (msg) ->
      {envelope} = msg
      if envelope.room is room and envelope.user.id is userId
        removeListenr listener
        if msg.envelope.message.text.toLowerCase() is 'cancel!'
          waitMsg.reply 'Canceled'
        else
          callback.apply null, arguments
    robot.listeners.push listener

  getHost = -> "#{HUBOT_QIITA_TEAM}.qiita.com"

  getAccessToken = (msg) ->
    userId = msg.envelope.user.id
    robot.brain.get(BRAIN_KEY_ACCESS_TOKENS)?[userId]

  checkAuthenticated = (msg) ->
    return token if token = getAccessToken msg
    msg.reply 'You are not authenticated yet. Send `hubot qiita authenticate me` to authenticate.'
    null

  httpScope = (path, params) ->
    accessToken = null
    if params?.token?
      accessToken = params.token
      delete params.token
    if params?.host?
      host = params.host
      delete params.host
    else
      host = getHost()
    http = robot
      .http("https://#{host}/api/v2/#{path}")
      .header('Content-Type', 'application/json')
      .header('Accept', 'application/json')
    if accessToken
      http.header 'Authorization', "Bearer #{accessToken}"
    http

  getAPI = (path, params, callback) ->
    if !callback? && typeof params is 'function'
      callback = params
      params = {}
    query = {}
    for k, v of params || {}
      query[k] = v unless k is 'token'
    qstr = qs.stringify query
    path += "?#{qstr}" if qstr.length > 0
    http = httpScope path, params
    http.get() (err, res, body) ->
      try
        body = JSON.parse body if typeof body is 'string'
      catch e
        err = e
      callback err, res, body

  postAPI = (path, params, callback) ->
    data = JSON.stringify params
    httpScope(path, params).post(data) (err, res, body) ->
      try
        body = JSON.parse body if typeof body is 'string'
      catch e
        err = e
      callback err, res, body

  ## Map of room -> listeners
  recordingSessions = {}

  robot.respond /\s*qiita\s+auth(?:enticate)?\s+me\s*$/i, (msg) ->
    crypto.randomBytes 20, (ex, buf) ->
      pendingToken = buf.toString 'hex'
      params =
        client_id: HUBOT_QIITA_CLIENT_ID
        state: pendingToken
        scope: scope
      url = "https://#{getHost()}/api/v2/oauth/authorize?#{qs.stringify params}"
      obj = robot.brain.get(BRAIN_KEY_PENDING_TOKEN) || {}
      { room, user } = msg.envelope
      obj[pendingToken] = { room, user }
      robot.brain.set BRAIN_KEY_PENDING_TOKEN, obj
      msg.reply "Visit this URL and authorize application: #{url}"

  robot.router.get '/qiita/callback', (httpReq, httpRes) ->
    { code, state } = httpReq.query
    pendingTokens = robot.brain.get BRAIN_KEY_PENDING_TOKEN
    unless envelope = pendingTokens?[state]
      httpRes.statusCode = 404
      httpRes.send 'Not found'
      return
    delete pendingTokens[state]
    robot.brain.remove pendingTokens
    params = {
      code: code
      client_secret: HUBOT_QIITA_CLIENT_SECRET
      client_id: HUBOT_QIITA_CLIENT_ID
      host: 'qiita.com'
    }
    postAPI 'access_tokens', params, (err, res, body) ->
      { token } = body
      if token?
        getAPI 'authenticated_user', { token }, (err, res, body) ->
          { id } = body
          if id?
            userId = envelope?.user?.id
            obj = robot.brain.get(BRAIN_KEY_ACCESS_TOKENS) || {}
            obj[userId] = token
            robot.brain.set BRAIN_KEY_ACCESS_TOKENS, obj
            robot.reply envelope, "Authenticated to Qiita with id:#{id}"
            httpRes.send 'OK'
          else
            httpRes.statusCode = 403
            httpRes.send 'NG'
      else
        httpRes.statusCode = 404
        httpRes.send 'NG'

  robot.respond /\s*qiita\s+(?:new|create)\s+(?:(coediting)\s+)?(?:item|post|entry)\s+with\s+template\s+(\d+)(?:\s+"([^"]+)")?\s*$/i, (msg) ->
    return unless token = checkAuthenticated msg
    coediting = msg.match[1]?.toLowerCase() is 'coediting'
    templateId = msg.match[2]
    title = msg.match[3]
    getAPI "templates/#{templateId}", { token }, (err, res, jsonBody) ->
      body = jsonBody['expanded_body']
      tags = jsonBody['expanded_tags']
      title ||= jsonBody['expanded_title']
      vars = {}
      doPost = ->
        for k, v of vars
          repl = (str) -> str.replace "%{#{k}}", v
          body  = repl body
          title = repl title
          tags = tags.map (t) ->
            t.name = repl t.name
            t
        params = { body, coediting, tags, title, token }
        postAPI 'items', params, (err, res, body) ->
          msg.reply "Created new #{ if coediting then 'coediting ' else '' }item *#{body.title}* https://#{getHost()}/items/#{body.id}"
      askNext = ->
        return do doPost unless varNames?.length > 0
        waitForResponse msg, (msg) ->
          vars[q] = msg.envelope.message.text
          do askNext
        q = varNames.shift()
        msg.reply "#{q}?"
      varNames = []
      addVarNames = (str) ->
        str.replace /%{([^\}]+)}/g, (s, p1) ->
          if varNames.indexOf(p1) == -1 and !/^hubot\:(user|room)$/.test(p1)
            varNames.push p1
      addVarNames body
      addVarNames title
      tags.forEach ({ name }) -> addVarNames name
      vars =
        'hubot:user': msg.envelope.user.name
        'hubot:room': msg.envelope.room
      do askNext

  robot.respond /\s*qiita\s+(?:list|ls)\s+templates?\s*$/i, (msg) ->
    return unless token = checkAuthenticated msg
    getAPI "templates", {token, per_page: 100}, (err, res, body) ->
      text = ['Listing templates:']
      for { id, name } in body
        text.push "#{id}: #{name}"
      msg.reply text.join "\n"

  robot.respond /\s*qiita\s+(?:list|ls)\s+stock(?:ed|s|)(?:\s+(?:items?|posts?|entr(?:y|ies)))?(?:\s+([^\s]+))?\s*$/i, (msg) ->
    return unless token = checkAuthenticated msg
    query = msg.match?[1]
    getAPI "authenticated_user", {token}, (err, res, body) ->
      getAPI "users/#{body.id}/stocks", {token, per_page: 100}, (err, res, jsonBody) ->
        text = ['Listing stocked items:']
        for { id, title, body } in jsonBody
          if !query? or body?.indexOf(query) >= 0 or title?.indexOf(query) >= 0
            text.push "#{title}: https://#{getHost()}/items/#{id}"
        msg.reply text.join "\n"

  robot.respond /\s*qiita\s+start\s+recording(?:\s+"([^"]+)")?\s*$/i, (msg) ->
    return unless checkAuthenticated msg
    { room, user } = msg.envelope
    if recordingSessions[room]
      msg.reply 'Already running recording session.'
      return
    dateString = dateformat new Date(), "yyyy/mm/dd HH:MM"
    title = msg.match?[1] || "Chat record #{dateString} on #{room}"
    buffer = ["# Recording started by #{user.name} at #{dateString}\n\n"]
    listener = new TextListener robot, /.*/, (msg) ->
      {envelope} = msg
      if envelope.room is room
        buffer.push "## #{dateformat new Date(), "yyyy/mm/dd HH:MM"} by #{envelope.user.name}\n\n#{envelope.message.text}\n\n"
    recordingSessions[room] = { listener, title, buffer }
    robot.listeners.push listener
    msg.reply 'Started recording session'

  robot.respond /\s*qiita\s+(stop|cancel)\s+recording\s*$/i, (msg) ->
    return unless token = checkAuthenticated msg
    { room, user } = msg.envelope
    unless session = recordingSessions[room]
      msg.reply 'No recording session running.'
      return
    delete recordingSessions[room]
    { buffer, title, listener } = session
    process.nextTick -> removeListenr listener
    body = buffer.join "\n"
    tags = [{name: room}]
    params = { body, tags, title, token }
    if msg.match[1]?.toLowerCase() is 'cancel'
      msg.reply 'Canceled'
    else
      postAPI 'items', params, (err, res, body) ->
        msg.reply "Created new item *#{body.title}* https://#{getHost()}/items/#{body.id}"
