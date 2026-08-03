import { CDID } from '@concrnt/client'

export interface ApImage {
    type: 'Image'
    url: string
    name: string | null
    sensitive: boolean
    mediaType?: string
}

export interface ApLink {
    type?: 'Link'
    href: string
    mediaType?: string
}

export interface ActivitypubMedia {
    mediaURL: string
    mediaType: string
    altText?: string
    blurhash?: string
    flag?: string
}

// APブリッジ(activitypub.concrnt.world)のフォローレコードキー。
// ハッシュはブリッジ側の CDID.makeHash と同一(keccak256先頭15バイトのx-CDID)。
export const apFollowKey = (ccid: string, actorURI: string): string => {
    return `cckv://${ccid}/activitypub.concrnt.world/follows/${CDID.newFromStringX(actorURI).toString()}`
}

export class ApObject {
    type: string = 'Object'
    id: string = ''
    inbox?: string
    outbox?: string
    followers?: string
    following?: string
    featured?: string
    sharedInbox?: string
    endpoints?: {
        sharedInbox: string
    }
    url?: string | ApLink | Array<string | ApLink>
    preferredUsername?: string
    name?: string
    summary?: string
    _misskey_summary?: string
    icon?: ApImage | ApImage[]
    image?: ApImage | ApImage[]
    tag?: ApObject | ApObject[]
    manuallyApprovesFollowers?: boolean
    discoverable?: boolean
    publicKey?: {
        id: string
        type: string
        owner: string
        publicKeyPem: string
    }
    attachment?: ApObject | ApObject[]
    mediaType?: string
    sensitive?: boolean
    blurhash?: string
    attributedTo?: string
    content?: string
    _misskey_content?: string
    published?: string
    to?: string[]
    cc?: string[]
    inReplyTo?: string

    constructor(ld: Partial<ApObject>) {
        Object.assign(this, ld)
    }

    getIcons(): ApImage[] {
        if (!this.icon) return []
        if (Array.isArray(this.icon)) return this.icon
        return [this.icon]
    }

    getImages(): ApImage[] {
        if (!this.image) return []
        if (Array.isArray(this.image)) return this.image
        return [this.image]
    }

    getTags(): ApObject[] {
        if (!this.tag) return []
        if (Array.isArray(this.tag)) return this.tag
        return [this.tag]
    }

    getAttachments(): ApObject[] {
        if (!this.attachment) return []
        if (Array.isArray(this.attachment)) return this.attachment
        return [this.attachment]
    }

    getAttachmentMedias(): ActivitypubMedia[] {
        const attachments = this.getAttachments()
        if (attachments.length === 0 && this.type === 'Note') {
            return this.getImages().map((image) => ({
                mediaURL: image.url,
                mediaType: image.mediaType ?? 'image/*',
                ...(image.name ? { altText: image.name } : {}),
                ...(image.sensitive ? { flag: 'sensitive' } : {})
            }))
        }

        return attachments.flatMap((attachment) => {
            const urls = Array.isArray(attachment.url) ? attachment.url : [attachment.url]
            const target = urls.find((url): url is string | ApLink => url != null)
            if (!target) return []

            const mediaURL = typeof target === 'string' ? target : target.href
            const mediaType =
                attachment.mediaType ??
                (typeof target === 'string' ? undefined : target.mediaType) ??
                ({ Image: 'image/*', Video: 'video/*', Audio: 'audio/*' }[attachment.type] ||
                    'application/octet-stream')

            return [
                {
                    mediaURL,
                    mediaType,
                    ...(attachment.name ? { altText: attachment.name } : {}),
                    ...(attachment.blurhash ? { blurhash: attachment.blurhash } : {}),
                    ...(attachment.sensitive || this.sensitive ? { flag: 'sensitive' } : {})
                }
            ]
        })
    }
}
