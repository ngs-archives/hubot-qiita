path = require 'path'
Robot = require("hubot/src/robot")
TextMessage = require("hubot/src/message").TextMessage
nock = require 'nock'
chai = require 'chai'
chai.use require 'chai-spies'
{ expect, spy } = chai

describe 'hubot-qiita', ->
  robot = null
  user = null
  adapter = null
  nockScope = null
  nockScope2 = null

  nextAdapterEvent = (event, done, callback) ->
    adapter.on event, ->
      try
        callback.apply @, arguments
      catch e
        console.error e
        done e

  beforeEach (done)->
    nock.disableNetConnect()
    nockScope = nock 'https://myteam.qiita.com'
    nockScope2 = nock 'https://qiita.com'
    process.env.HUBOT_QIITA_TEAM = 'myteam'
    process.env.HUBOT_QIITA_CLIENT_ID = 'abcd1234abcd1234abcd1234abcd1234abcd1234'
    process.env.HUBOT_QIITA_CLIENT_SECRET = '4321dcba4321dcba4321dcba4321dcba4321dcba'
    robot = new Robot null, 'mock-adapter', yes, 'TestHubot'
    nock.enableNetConnect '127.0.0.1'
    robot.adapter.on 'connected', ->
      robot.loadFile path.resolve('.', 'src', 'scripts'), 'qiita.coffee'
      hubotScripts = path.resolve 'node_modules', 'hubot', 'src', 'scripts'
      robot.loadFile hubotScripts, 'help.coffee'
      user = robot.brain.userForId '1', {
        name: 'ngs'
        room: '#mocha'
      }
      anotherUser = robot.brain.userForId '2', {
        name: 'pyc'
        room: '#mocha'
      }
      adapter = robot.adapter
      waitForHelp = ->
        if robot.helpCommands().length > 0
          do done
        else
          setTimeout waitForHelp, 100
      do waitForHelp
    do robot.run

  afterEach ->
    robot.server.close()
    robot.shutdown()
    nock.cleanAll()
    process.removeAllListeners 'uncaughtException'

  describe 'help', ->
    it 'should have 9', (done)->
      expect(robot.helpCommands()).to.have.length 9
      do done

    it 'should parse help', (done)->
      nextAdapterEvent 'send', done, (envelope, strings)->
        expect(strings).to.deep.equal ["""
        TestHubot help - Displays all of the help commands that TestHubot knows about.
        TestHubot help <query> - Displays all help commands that match <query>.
        TestHubot qiita authenticate me - Authenticate with Qiita account
        TestHubot qiita list stocked items
        TestHubot qiita list templates
        TestHubot qiita new coediting item with template <template id> title <title>
        TestHubot qiita new item with template <template id> "<title>"
        TestHubot qiita start recording "<title>" - Start recording chat room
        TestHubot qiita stop recording
        """]
        do done
      adapter.receive new TextMessage user, 'TestHubot help'

  describe 'authentication', (done)->
    [
      'testhubot  qiita  authenticate  me  '
      'testhubot  qiita  auth  me  '
    ].forEach (msg)->
      describe msg, ->
        it 'should reply authenticate url', (done)->
          nextAdapterEvent 'reply', done, (envelope, strings)->
            obj = robot.brain.get 'qiita.pending_tokens'
            pendingToken = Object.keys(obj)[0]
            expect(pendingToken).to.match /^[a-f0-9]{40}$/
            expect(obj[pendingToken]).to.deep.equal { room: '#mocha', user: { name: 'ngs', room: '#mocha', id: '1' } }
            expect(strings).to.deep.equal ["Visit this URL and authorize application: https://myteam.qiita.com/api/v2/oauth/authorize?client_id=abcd1234abcd1234abcd1234abcd1234abcd1234&state=#{pendingToken}&scope=read_qiita_team%20write_qiita_team%20read_qiita%20write_qiita"]
            do done
          adapter.receive new TextMessage user, msg
    describe 'Handle callbacks', ->
      beforeEach ->
        robot.brain.set 'qiita.pending_tokens', asdfasdf: '1'
        nockScope2 = nockScope2
          .post('/api/v2/access_tokens').reply 201,
            client_id: 'a91f0396a0968ff593eafdd194e3d17d32c41b1da7b25e873b42e9058058cd9d'
            scopes: ['all'],
            token: 'ea5d0a593b2655e9568f144fb1826342292f5c6b7d406fda00577b8d1530d8a5'
        nockScope = nockScope
          .get('/api/v2/authenticated_user').reply 200, { id: 'ngs' }

      it 'handles callback', (done) ->
        adapter.on 'reply', (envelope, strings)->
          try
            expect(strings).to.deep.equal ['Authenticated to Qiita with id:ngs']
            expect(robot.brain.get('qiita.pending_tokens')).to.deep.equal {}
            do done
          catch e
            done e
        robot.http('http://127.0.0.1:8080/qiita/callback?state=asdfasdf&code=1234')
          .get() (err, res, body) ->
            expect(body).to.equal 'OK'

  describe 'templates', ->
    beforeEach ->
      robot.brain.set 'qiita.access_tokens', { '1': 'asdfasdf' }
      data = for i in [1...4]
        body: "日報のひな形#{i}です。"
        id: i
        name: "日報 #{i}"
        expanded_body: "<%=  user  %> 日報 <%= date  %> のひな形です。"
        expanded_tags: [
          name: "example tag"
          versions: ["0.0.#{i}"]
        ]
        expanded_title: "2014/09/2#{i}日報"
        tags: [
          name: "example tag"
          versions: ["0.0.#{i}"]
        ]
        title: "%{Year}/%{month}/%{day}日報"
      nockScope = nockScope
        .get('/api/v2/templates?per_page=100').reply 200, data
    [
      'testhubot  qiita  list  templates '
      'testhubot  qiita  ls  template  '
    ].forEach (msg)->
      describe msg, ->
        it 'list templates', (done)->
          nextAdapterEvent 'reply', done, (envelope, strings)->
            expect(strings).to.deep.equal ["""
            Listing templates:
            1: 日報 1
            2: 日報 2
            3: 日報 3
            """]
            do done
          adapter.receive new TextMessage user, msg

  describe 'stocks', ->
    beforeEach ->
      robot.brain.set 'qiita.access_tokens', { '1': 'asdfasdf' }
      data = for i in [1...4]
        title: "日報#{i}"
        id: i
      nockScope = nockScope
        .get('/api/v2/users/ngs/stocks?per_page=100').reply 200, data
        .get('/api/v2/authenticated_user').reply 200, id: 'ngs'
    [
      'testhubot  qiita  list  stocked  items '
      'testhubot  qiita  ls  stocked  '
      'testhubot  qiita  ls  stock '
      'testhubot  qiita  ls  stocks '
    ].forEach (msg)->
      describe msg, ->
        it 'list stocked', (done)->
          nextAdapterEvent 'reply', done, (envelope, strings)->
            expect(strings).to.deep.equal ["""
            Listing stocked items:
            日報1: https://myteam.qiita.com/items/1
            日報2: https://myteam.qiita.com/items/2
            日報3: https://myteam.qiita.com/items/3
            """]
            do done
          adapter.receive new TextMessage user, msg


    [
      'testhubot  qiita  list  stocked  items  2 '
      'testhubot  qiita  ls  stocked 2  '
      'testhubot  qiita  ls  stock  2 '
      'testhubot  qiita  ls  stocks 2  '
    ].forEach (msg)->
      describe msg, ->
        it 'queries entries', (done)->
          nextAdapterEvent 'reply', done, (envelope, strings) ->
            expect(strings).to.deep.equal ["""
            Listing stocked items:
            日報2: https://myteam.qiita.com/items/2
            """]
            do done
          adapter.receive new TextMessage user, msg

  describe 'item', ->
    beforeEach ->
      robot.brain.set 'qiita.access_tokens', { '1': 'asdfasdf' }
      nockScope = nockScope
        .get('/api/v2/templates/123').reply 200,
          body: "日報のひな形です。"
          id: 1
          name: "日報"
          expanded_body: "日報のひな形です。 %{hubot:user} %{hubot:room} "
          expanded_tags: [
            name: "example tag %{hubot:room}"
            versions: ["0.0.1"]
          ]
          expanded_title: "2014/09/26 %{hubot:user} %{hubot:room} 日報 %{summary} "
          tags: [
            name: "example tag %{hubot:room}"
            versions: ["0.0.1"]
          ]
          title: "%{Year}/%{month}/%{day} %{hubot.user} %{hubot.room} 日報 %{summary} "
        .post('/api/v2/items').reply 201,
          body: "puts 'hello world'"
          id: "4bd431809afb1bb99e4f"
          title: 'hello world'

    describe 'create coediting item', ->
      [
        'testhubot  qiita  create  coediting  item  with  template  123 '
        'testhubot  qiita  new  coediting  entry  with  template  123  '
      ].forEach (msg)->
        describe msg, ->
          it 'craetes coediting entry', (done)->
            count = 0
            nextAdapterEvent 'reply', done, (envelope, strings)->
              expect(strings).to.deep.equal [[
                'summary?'
                'Created new coediting item *hello world* https://myteam.qiita.com/items/4bd431809afb1bb99e4f'
              ][count++]]
              do done if count == 2
              adapter.receive new TextMessage user, 'test foo bar'
            adapter.receive new TextMessage user, msg

    describe 'create item', (done)->
      [
        'testhubot  qiita  create  item  with  template  123  "abcd  efgh" '
        'testhubot  qiita  new  entry  with  template  123  "abcd  efgh"  '
      ].forEach (msg)->
        describe msg, ->
          it 'craetes coediting item', (done) ->
            nextAdapterEvent 'reply', done, (envelope, strings)->
              expect(strings).to.deep.equal ['Created new item *hello world* https://myteam.qiita.com/items/4bd431809afb1bb99e4f']
              do done
            adapter.receive new TextMessage user, msg

  describe 'recording', ->
    beforeEach ->
      robot.brain.set 'qiita.access_tokens', { '1': 'asdfasdf' }
      nockScope
        .post('/api/v2/items').reply 201,
          body: "puts 'hello world'"
          id: "4bd431809afb1bb99e4f"
          title: 'hello world'
    [
      'testhubot  qiita  start  recording  "abcd  efgh" '
      'testhubot  qiita  start  recording  '
    ].forEach (msg)->
      describe msg, ->
        it 'starts recording session', (done) ->
          count = 0
          nextAdapterEvent 'reply', done, (envelope, strings)->
            expect(strings).to.deep.equal [[
              'Started recording session'
              'Already running recording session.'
              'Created new item *hello world* https://myteam.qiita.com/items/4bd431809afb1bb99e4f'
              'No recording session running.'
            ][count]]
            expect(robot.listeners).to.have.length if count < 2 then 8 else 7
            switch ++count
              when 1    then adapter.receive new TextMessage user, m for m in [msg, 'foo', 'bar', 'baz']
              when 2, 3 then adapter.receive new TextMessage user, 'testhubot  qiita  stop  recording'
              else do done
          expect(robot.listeners).to.have.length 7
          adapter.receive new TextMessage user, msg
