import { Document, SignedDocument } from '@concrnt/client'
import { Schemas } from './schemas'
import { LikeAssociationSchema, ProfileSchema, ReactionAssociationSchema } from './schemas/'
import { User } from './user'
import { Client } from './client'
import { Association } from './association'
import { semantics } from './semantics'

export class Message<T> implements Document<T> {
    uri: string
    kind: 'record'
    key?: string
    schema: string
    value: T
    author: string
    createdAt: Date
    distributes?: string[]
    associate?: string

    hint?: string

    authorUser?: User

    associations: Array<Association<any>> = []
    ownAssociations: Array<Association<any>> = []
    ownAssociationsLoaded: boolean = false

    associationCounts?: Record<string, number>
    reactionCounts?: Record<string, number>

    associationTarget?: Message<any> | null

    authorProfileName: string | null = null
    authorProfile: ProfileSchema = {
        username: 'Anonymous'
    }

    toJSON(): Document<T> & { uri: string } {
        return {
            uri: this.uri,
            kind: this.kind,
            key: this.key,
            schema: this.schema,
            value: this.value,
            author: this.author,
            createdAt: this.createdAt,
            distributes: this.distributes,
            associate: this.associate
        }
    }

    constructor(uri: string, document: Document<T>) {
        this.uri = uri
        this.kind = 'record'
        this.key = document.key
        this.schema = document.schema
        this.value = document.value
        this.author = document.author
        this.createdAt = new Date(document.createdAt)
        this.distributes = document.distributes
        this.associate = document.associate
    }

    static async load<T>(client: Client, uri: string, hint?: string): Promise<Message<T> | null> {
        const res = await client.api.getDocument<T>(uri, hint)
        if (!res) {
            return null
        }
        const message = new Message<T>(uri, res)
        message.hint = hint
        message.authorUser = await User.load(client, message.author, hint).catch(() => undefined)
        if (message.authorUser?.profile) {
            message.authorProfile = { ...message.authorProfile, ...message.authorUser.profile }
        }

        const key = message.key
        //  `cckv://${owner}/concrnt.world/profiles/${profile}/posts/${postId}`,
        const profileName = key?.split('/')[5]
        if (profileName) {
            console.log('profile name', profileName)
            message.authorProfileName = profileName
            const profile = await client.api
                .getDocument<ProfileSchema>(semantics.profile(message.author, profileName))
                .then((res) => res.value)
                .catch(() => undefined)
            if (profile) {
                message.authorProfile = profile
            }
        }
        if ((res.value as any).profileOverride) {
            const override = (res.value as any).profileOverride
            if (override.username) {
                message.authorProfile.username = override.username
            }
            if (override.avatar) {
                message.authorProfile.avatar = override.avatar
            }
        }

        // 本文取得後の付帯情報は表示の必須条件ではない。v1専用サーバーや一時的な
        // association API障害でも、取得できた本文までエラー表示に巻き込まない。
        if (client.ccid) {
            try {
                message.ownAssociations = (await client.api.getAssociationsAll(uri, { author: client.ccid })).map(
                    (sd) => Association.fromSignedDocument(sd)
                )
                message.ownAssociationsLoaded = true
            } catch (_error) {
                // 「取得済みで0件」と区別し、アクション側で重複commitを防ぐ。
                message.ownAssociations = []
                message.ownAssociationsLoaded = false
            }
        } else {
            // ゲストは自分のassociationを持たず、書き込み操作も表示されない。
            message.ownAssociations = []
            message.ownAssociationsLoaded = true
        }

        message.associationCounts = await client.api.getAssociationCounts(uri).catch(() => ({}))
        message.reactionCounts = await client.api
            .getAssociationCounts(uri, Schemas.reactionAssociation)
            .catch(() => ({}))

        if (res.associate) {
            message.associationTarget = await Message.load<any>(client, res.associate).catch(() => undefined)
        }

        return message
    }

    async favorite(client: Client): Promise<SignedDocument> {
        if (!this.ownAssociationsLoaded) {
            throw new Error('cannot add favorite while own association state is unavailable')
        }
        const authorDomain = await client.api.getEntity(this.author, this.hint).then((user) => user?.value.domain)
        console.log('fav author domain', authorDomain)

        const distributes = [
            semantics.activityTimeline(client.ccid, client.currentProfile),
            semantics.notificationTimeline(this.author, this.authorProfileName || 'main')
        ]

        const document: Document<LikeAssociationSchema> = {
            kind: 'association',
            author: client.ccid,
            schema: Schemas.likeAssociation,
            associate: this.uri,
            value: {},
            distributes,
            createdAt: new Date()
        }

        return client.api.commit(document, authorDomain)
    }

    async reaction(client: Client, shortcode: string, imageUrl: string): Promise<SignedDocument> {
        if (!this.ownAssociationsLoaded) {
            throw new Error('cannot add reaction while own association state is unavailable')
        }
        const authorDomain = await client.api.getEntity(this.author, this.hint).then((user) => user?.value.domain)

        const distributes = [
            semantics.activityTimeline(client.ccid, client.currentProfile),
            semantics.notificationTimeline(this.author, this.authorProfileName || 'main')
        ]

        const document: Document<ReactionAssociationSchema> = {
            kind: 'association',
            author: client.ccid,
            schema: Schemas.reactionAssociation,
            associate: this.uri,
            associationVariant: imageUrl,
            value: {
                shortcode,
                imageUrl
            },
            distributes,
            createdAt: new Date()
        }

        return client.api.commit(document, authorDomain)
    }
}
