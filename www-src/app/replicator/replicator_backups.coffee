DeviceStatus = require '../lib/device_status'
fs = require './filesystem'
request = require '../lib/request'
Contact = require '../models/contact'

# Account type and name of the created android contact account.
CONTACT_PHONE_ACCOUNT_TYPE = 'io.cozy'
CONTACT_PHONE_ACCOUNT_NAME = 'myCozy'

# This files contains all replicator functions liked to backup
# use the ImagesBrowser cordova plugin to fetch images & contacts
# from phone.
# Set the inBackup attribute to true while a backup is in progress
# Set the backup_step attribute with value in
# [contacts_scan, pictures_sync, contacts_sync]
# For each step, hint of progress are in backup_step_done and backup_step_total

module.exports =

    # wrapper around _backup to maintain the state of inBackup
    backup: (options, callback = ->) ->
        return callback null if @get 'inBackup'

        options = options or { force: false }

        @set 'inBackup', true
        @set 'backup_step', null
        @stopRealtime()
        @_backup options.force, (err) =>
            @set 'backup_step', null
            @set 'inBackup', false
            @startRealtime() unless options.background
            return callback err if err
            @config.save lastBackup: new Date().toString(), (err) =>
                callback null


    _backup: (force, callback) ->
        DeviceStatus.checkReadyForSync true, (err, ready, msg) =>
            console.log "SYNC STATUS", err, ready, msg
            return callback err if err
            return callback new Error(msg) unless ready
            console.log "WE ARE READY FOR SYNC"

            # @syncPictures force, (err) =>
            #     console.log "done syncPict"
            #     return callback err if err
            #     @syncCache (err) =>
            #         console.log "done syncCache"
                    # return callback err if err
            @syncContacts (err) =>
                console.log err
                callback err


    syncContacts: (callback) ->
        return callback null unless @config.get 'syncContacts'

        # Phone is right on conflict.
        # Contact sync has 3 phases
        # 1 - Phone2Pouch
        # 2 - Pouch <-> Couch (cozy)
        # 3 - Pouch2Phone.

        async.series [
            @_createAccount
            @_syncPhone2Pouch
            # @_syncWithCozy
            @_syncToCozy
            @_syncFromCozy
            @_syncPouch2Phone
            ], callback

    _createAccount: (callback) =>
        navigator.contacts.createAccount 'io.cozy', 'myCozy'
        , ->
            console.log 'create account success!!'
            callback null
        , (err) ->
            console.log 'create account err!!'
            console.log err
            callback err


    _syncToCozy: (callback) =>
        # Get contacts from the cozy (couch -> pouch replication)
        console.log "checkpointedPush: #{app.replicator.config.get 'contactsPushCheckpointed'}"
        replication = app.replicator.db.replicate.to app.replicator.config.remote,
            batch_size: 20
            batches_limit: 5
            filter: (doc) ->
                return doc? and doc.docType?.toLowerCase() is 'contact' # and
                    #not doc._deleted # TODO ! should not need this ! # Pb with attachments ?
            live: false
            #since: app.replicator.config.get 'contactsPushCheckpointed'

        replication.on 'change', (e) =>
            console.log "Replication Change"
            console.log e
        replication.on 'error', callback
        replication.on 'complete', (result) =>
            console.log "REPLICATION COMPLETED contacts"
            console.log result
            app.replicator.config.save contactsPushCheckpointed: result.last_seq,  callback


    _syncFromCozy: (callback) =>
        # Get contacts from the cozy (couch -> pouch replication)
        console.log "checkpointedPull: #{app.replicator.config.get 'contactsPullCheckpointed'}"
        replication = app.replicator.db.replicate.from app.replicator.config.remote,
            batch_size: 20
            batches_limit: 5
            filter: (doc) ->
                return doc? and doc.docType?.toLowerCase() is 'contact' # and
                    #not doc._deleted # TODO ! should not need this ! # Pb with attachments ?
            live: false
            since: app.replicator.config.get 'contactsPullCheckpointed'

        replication.on 'change', (e) =>
            console.log "Replication Change"
            console.log e
        replication.on 'error', callback
        replication.on 'complete', (result) =>
            console.log "REPLICATION COMPLETED contacts"
            console.log result
            app.replicator.config.save contactsPullCheckpointed: result.last_seq, callback


    _syncPouch2Phone: (callback) ->
        # TODO: option : list of changed documents.
        console.log '_syncPouch2Phone'

        # Get contacts list
        async.parallel
            contacts: (cb) ->
                app.replicator.db.query 'Contacts', { include_docs: true, attachments: true }, cb
            syncInfos: (cb) ->
                # All docs but no design ones.
                app.replicator.contactsDB.query 'ByCozyContactId', { include_docs: true} , cb

        , (err, results) ->
            if err
                console.log err
                return callback err

            syncInfos = {}
            results.syncInfos.rows.forEach (row) ->
                doc = row.doc
                syncInfos[doc.pouchId] = doc

            async.eachSeries results.contacts.rows, (row, cb) =>
                cozyContact = row.doc

                if cozyContact._id of syncInfos # Contact already exists.
                    syncInfo = syncInfos[cozyContact._id]
                    # Mark as viewed to identify deleted contacts later.
                    delete syncInfos[cozyContact._id]

                    if syncInfo.pouchRev isnt cozyContact._rev
                        console.log '# Needs update !'
                        contact = Contact.cozy2Cordova cozyContact
                        contact.id = syncInfo.localId
                        contact.rawId = syncInfo.localRawId
                        app.replicator._saveContactOnPhone cozyContact, contact, syncInfo, cb

                    else
                        cb()

                else
                    console.log '# Not synced yet !'
                    contact = Contact.cozy2Cordova cozyContact
                    app.replicator._saveContactOnPhone cozyContact, contact, {}, cb

            , (err) ->
                    return callback err if err
                    # Remaining syncInfos are contact to delete from pouch.
                    toDelete = _.values syncInfos
                    console.log toDelete
                    async.eachSeries toDelete, @_deleteContactOnPhone, callback

    _syncPhone2Pouch: (callback) =>
        # Get the contacts, and syncInfos.
        async.parallel [
            (cb) ->
                options = new ContactFindOptions "", true, [], 'io.cozy', 'myCozy'
                fields = [navigator.contacts.fieldType.id]

                navigator.contacts.find fields
                , (contacts) ->
                    console.log "CONTACTS FROM PHONE : #{contacts.length}"
                    cb null, contacts
                , cb
                , options
            (cb) ->
                # All docs but no design ones.
                app.replicator.contactsDB.query 'ByCozyContactId', { include_docs: true} , cb
            ],
            (err, results) ->
                [contacts, syncResults] = results
                syncInfos = {}
                console.log syncResults
                syncResults.rows.forEach (row) ->
                    doc = row.doc
                    syncInfos[doc.localId] = doc


                async.eachSeries contacts, (contact, cb) =>
                    console.log contact

                    if contact.id of syncInfos  # Contact already exists
                        syncInfo = syncInfos[contact.id]
                        # Mark as viewed to identify deleted contacts later.
                        delete syncInfos[contact.id]

                        if syncInfo.localRev isnt contact.version
                            console.log '# Phone2Pouch Needs update !'
                            app.replicator._saveContactInCozy contact, syncInfo, cb
                        else
                            cb()

                    else
                        console.log '# New contact from phone !'
                        app.replicator._saveContactInCozy contact, null, cb

                , (err) ->
                    return callback err if err
                    # Remaining syncInfos are contact to delete from pouch.
                    toDelete = _.values syncInfos
                    console.log toDelete
                    async.eachSeries toDelete, @_deleteContactInCozy, callback

    _deleteContactOnPhone: (syncInfo, callback) ->
        console.log "delete contact !"
        console.log syncInfo
        # delete contact in phone
        phoneContact = navigator.contacts.create { id: syncInfo.localId }

        phoneContact.remove -> # onSuccess
            # delete syncInfo object
            app.replicator.contactsDB.remove syncInfo, callback

        , callback # onError

    _deleteContactInCozy: (syncInfo, callback) ->
        console.log "delete contact !"
        console.log syncInfo
        # delete contact in db
        app.replicator.db.remove syncInfo.pouchId, syncInfo.pouchRev, (err, res) ->
            return callback err if err

            # delete syncInfo object
            app.replicator.contactsDB.remove syncInfo, callback

    _saveContactInCozy: (contact, syncInfo, callback) =>
        Contact.cordova2Cozy contact, (err, cozyContact) =>
            doneCallback = (err, result) =>
                return cb err if err

                cozyContact._id = result.id
                cozyContact._rev = result.rev

                app.replicator._updateSyncInfo cozyContact, contact, syncInfo \
                    , callback

            if syncInfo?
                cozyContact._id = syncInfo.pouchId
                cozyContact._rev = syncInfo.pouchRev
                app.replicator.db.put cozyContact, syncInfo.pouchId, \
                    syncInfo.pouchRev, doneCallback

            else
                app.replicator.db.post cozyContact, doneCallback

    _saveContactOnPhone: (cozyContact, contact, syncInfo, callback) =>
        options =
            accountType: 'io.cozy'
            accountName: 'myCozy'

        onSuccess = (phoneContact) -> # onSuccess
            app.replicator._updateSyncInfo cozyContact, phoneContact, syncInfo, callback

        contact.save onSuccess, callback, options # onSuccess, onError, options.


    _updateSyncInfo: (cozyContact, contact, syncInfo, callback) =>
        syncInfo = syncInfo or {}
        _.extend syncInfo,
                pouchId: cozyContact._id
                pouchRev: cozyContact._rev
                localId: contact.id
                localRawId: contact.rawId
                localRev: contact.version

        if syncInfo._id?
            app.replicator.contactsDB.put syncInfo, \
                syncInfo._id, syncInfo._rev, callback

        else
            app.replicator.contactsDB.post syncInfo, callback

    syncContacts_old: (callback) ->
        return callback null unless @config.get 'syncContacts'

        console.log "SYNC CONTACTS"
        @set 'backup_step', 'contacts_scan'
        @set 'backup_step_done', null
        async.parallel [
            ImagesBrowser.getContactsList
            (cb) => @contactsDB.query 'ContactsByLocalId', {}, cb
        ], (err, result) =>
            return callback err if err
            [phoneContacts, rows: dbContacts] = result

            # for test purpose
            # phoneContacts = phoneContacts[0..50]

            console.log "BEGIN SYNC #{dbContacts.length} #{phoneContacts.length}"

            dbCache = {}
            dbContacts.forEach (row) ->
                dbCache[row.key] =
                    id: row.id
                    rev: row.value[1]
                    version: row.value[0]

            processed = 0
            @set 'backup_step_total', phoneContacts.length

            async.eachSeries phoneContacts, (contact, cb) =>
                @set 'backup_step_done', processed++


                contact.localId = contact.localId.toString()
                contact.docType = 'Contact'
                inDb = dbCache[contact.localId]

                log = "CONTACT : #{contact.localId} #{contact.localVersion}"
                log += "DB #{inDb?.version} : "

                # no changes
                if contact.localVersion is inDb?.version
                    console.log log + "NOTHING TO DO"
                    cb null

                # the contact already exists, but has changed, we update it
                else if inDb?
                    console.log log + "UPDATING"
                    @contactsDB.put contact, inDb.id, inDb.rev, cb

                # this is a new contact
                else
                    console.log log + "CREATING"
                    @contactsDB.post contact, (err, doc) ->
                        return callback err if err
                        return callback new Error('cant create') unless doc.ok
                        dbCache[contact.localId] =
                            id: doc.id
                            rev: doc.rev
                            version: contact.localVersion
                        cb null

            , (err) =>
                return callback err if err
                console.log "SYNC CONTACTS phone -> pouch DONE"

                # extract the ids
                ids = _.map dbCache, (doc) -> doc.id
                @set 'backup_step', 'contacts_sync'
                @set 'backup_step_total', ids.length

                replication = @contactsDB.replicate.to @config.remote,
                    since: 0, doc_ids: ids

                replication.on 'error', callback
                replication.on 'change', (e) =>
                    @set 'backup_step_done', e.last_seq
                replication.on 'complete', =>
                    callback null
                    # we query the view to force rebuilding the mapreduce index
                    @contactsDB.query 'ContactsByLocalId', {}, ->



    syncPictures: (force, callback) ->
        return callback null unless @config.get 'syncImages'

        console.log "SYNC PICTURES"
        @set 'backup_step', 'pictures_scan'
        @set 'backup_step_done', null
        async.series [
            @ensureDeviceFolder.bind this
            ImagesBrowser.getImagesList
            (callback) => @photosDB.query 'PhotosByLocalId', {}, callback
            (cb) => @db.query 'FilesAndFolder',
                {
                    startkey: ['/' + t 'photos']
                    endkey: ['/' + t('photos'), {}]
                } , cb
        ], (err, results) =>
            return callback err if err
            [device, images, rows: dbImages, dbPictures] = results

            dbImages = dbImages.map (row) -> row.key
            # We pick up the filename from the key to improve speed :
            # query without include_doc are 100x faster
            dbPictures = dbPictures.rows.map (row) -> row.key[1]?.slice 2

            myDownloadFolder = @downloads.toURL().replace 'file://', ''

            toUpload = []

            # Filter images : keep only the ones from Camera
            # TODO: Android Specific !
            images = images.filter (path) -> path.indexOf('/DCIM/') != -1

            if images.length is 0
                callback new Error 'no images in DCIM'

            # step 1 scan all images, find the new ones
            async.eachSeries images, (path, cb) =>
                #Check if pictures is in dbImages
                if path in dbImages
                    cb()
                else
                    # Check if pictures is already present (old installation)
                    fs.getFileFromPath path, (err, file) =>
                        # We test only on filename, case-insensitive
                        if file.name?.toLowerCase() in dbPictures
                            # Add photo in local database
                            @createPhoto path
                        else
                            # Create file
                            toUpload.push path

                        DeviceStatus.checkReadyForSync (err, ready, msg) ->
                            return cb err if err
                            return cb new Error msg unless ready

                            setTimeout cb, 1 # don't freeze UI


            , =>
                # step 2 upload one by one
                console.log "SYNC IMAGES : #{images.length} #{toUpload.length}"
                processed = 0
                @set 'backup_step', 'pictures_sync'
                @set 'backup_step_total', toUpload.length
                async.eachSeries toUpload, (path, cb) =>
                    @set 'backup_step_done', processed++
                    console.log "UPLOADING #{path}"
                    @uploadPicture path, device, (err) =>
                        console.log "ERROR #{path} #{err}" if err
                        DeviceStatus.checkReadyForSync (err, ready, msg) ->
                            return cb err if err
                            return cb new Error msg unless ready

                            setTimeout cb, 1 # don't freeze UI.

                , callback

    uploadPicture: (path, device, callback) ->
        fs.getFileFromPath path, (err, file) =>
            return callback err if err

            fs.contentFromFile file, (err, content) =>
                return callback err if err

                @createBinary content, file.type, (err, bin) =>
                    return callback err if err

                    @createFile file, path, bin, device, (err, res) =>
                        return callback err if err

                        @createPhoto path, callback


    createBinary: (blob, mime, callback) ->
        @config.remote.post docType: 'Binary', (err, doc) =>
            return callback err if err
            return callback new Error('cant create binary') unless doc.ok

            @config.remote.putAttachment doc.id, 'file', doc.rev, blob, mime, (err, doc) =>
                return callback err if err
                return callback new Error('cant attach') unless doc.ok
                callback null, doc

    createFile: (cordovaFile, localPath, binaryDoc, device, callback) ->
        dbFile =
            docType          : 'File'
            localPath        : localPath
            name             : cordovaFile.name
            path             : "/" + t('photos')
            class            : @fileClassFromMime cordovaFile.type
            lastModification : new Date(cordovaFile.lastModified).toISOString()
            creationDate     : new Date(cordovaFile.lastModified).toISOString()
            size             : cordovaFile.size
            tags             : ['from-' + @config.get 'deviceName']
            binary: file:
                id: binaryDoc.id
                rev: binaryDoc.rev

        @config.remote.post dbFile, callback

    createPhoto: (localPath, callback) ->
        dbPhoto =
            docType : 'Photo'
            localId: localPath
        @photosDB.post dbPhoto, callback

    fileClassFromMime: (type) ->
        return switch type.split('/')[0]
            when 'image' then "image"
            when 'audio' then "music"
            when 'video' then "video"
            when 'text', 'application' then "document"
            else "file"

    ensureDeviceFolder: (callback) ->
        findDevice = (id, callback) =>
            @db.get id, (err, res) ->
                if not err?
                    callback()
                else
                    findDevice id, callback

        createNew = () =>
            console.log "MAKING ONE"
            # no device folder, lets make it
            folder =
                docType          : 'Folder'
                name             : t 'photos'
                path             : ''
                lastModification : new Date().toISOString()
                creationDate     : new Date().toISOString()
                tags             : []
            options =
                key: ['', "1_#{folder.name.toLowerCase()}"]
            @config.remote.post folder, (err, res) =>
                app.replicator.startRealtime()
                # Wait to receive folder in local database
                findDevice res.id, () ->
                    return callback err if err
                    callback null, folder

        @db.query 'FilesAndFolder', key: ['', "1_#{t('photos').toLowerCase()}"], (err, results) =>
            return callback err if err
            if results.rows.length > 0
                device = results.rows[0]
                console.log "DEVICE FOLDER EXISTS"
                return callback null, device
            else
                # TODO : relies on byFullPath folder view of cozy-file !
                query = '/_design/folder/_view/byfullpath/?' +
                    "key=\"/#{t('photos')}\""

                request.get @config.makeUrl(query), (err, res, body) ->
                    return callback err if err
                    if body?.rows?.length is 0
                        createNew()
                    else
                        # already exist remote, but not locally...
                        callback new Error 'photo folder not replicated yet'
