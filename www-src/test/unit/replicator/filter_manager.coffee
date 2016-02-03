should = require('chai').should()
mockery = require 'mockery'

module.exports = describe 'FilterManager Test', ->

    defaultId = 42
    cozyUrl = 'cozyUrl'
    deviceName = "my-device"
    db =
        put: (doc, callback) -> callback null, doc
        get: (id, callback) -> callback 'missing' # TODO : better PouchDB mock

    before ->
        mockery.enable
            warnOnReplace: false
            warnOnUnregistered: false
            useCleanCache: true

        requestMock =
            put: (options, callback) ->
                if options.auth == "err"
                    callback "err", undefined, undefined
                else if options.auth == "body_empty"
                    callback undefined, undefined, {}
                else if options.auth
                    callback undefined, undefined, success: true
                else
                    callback undefined, undefined, undefined
            get: (options, callback) ->
                if options.auth == "err"
                    callback "err", undefined, undefined
                else if options.auth == "body_empty"
                    callback undefined, undefined, {}
                else if options.auth
                    callback undefined, undefined, _id: defaultId
                else
                    callback undefined, undefined, undefined

        mockery.registerMock '../lib/request', requestMock
        @FilterManager = require '../../../app/replicator/filter_manager'

    after ->
        mockery.deregisterAll()
        delete @FilterManager
        mockery.disable()

    describe '[When all is ok]', ->

        it "setFilter return true", (done) ->
            filterManager = new @FilterManager cozyUrl, true, deviceName, db
            filterManager.setFilter true, true, true, (err, response) ->
                response.should.be.equal true
                done()

        it "getFilterName return the filter name", ->
            filterManager = new @FilterManager cozyUrl, true, deviceName, db
            name = filterManager.getFilterName()
            name.should.be.equal "filter-#{deviceName}-config/config"


    describe '[All errors]', ->

        it "When API have an error setFilter return err", (done) ->
            filterManager = new @FilterManager cozyUrl, "err", deviceName, db
            filterManager.setFilter true, true, true, (err, response) ->
                err.should.not.to.be.null
                done()

        it "When API don't return _id setFilter return false", (done) ->
            filterManager = new @FilterManager cozyUrl, "body_empty", \
                                    deviceName, db
            filterManager.setFilter true, true, true, (err, response) ->
                err.should.not.to.be.null
                done()
