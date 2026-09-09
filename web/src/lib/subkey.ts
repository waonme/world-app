import { Api, ComputeCKID, Document, GenerateIdentity, InMemoryAuthProvider, InMemoryKVS } from '@concrnt/client'
import { semantics } from '@concrnt/worldlib'

// マスターキーを明示的に使う再登録フローとv1移行で共用する。
// 戻り値を保存してから再読み込みすることで、ClientProviderは通常のsubkeyセッションとして起動できる。
export const provisionSubkey = async (domain: string, masterKey: string): Promise<string> => {
    const masterProvider = new InMemoryAuthProvider(masterKey)
    const ccid = masterProvider.getCCID()
    const api = new Api(domain, masterProvider, new InMemoryKVS())
    const subIdentity = GenerateIdentity()
    const ckid = ComputeCKID(subIdentity.publicKey)
    const subkeyDoc: Document<{ ckid: string }> = {
        kind: 'record',
        key: semantics.subkey(ccid, ckid),
        author: ccid,
        schema: 'https://schema.concrnt.net/subkey.json',
        value: { ckid },
        createdAt: new Date(),
        onUpdate: 'retain'
    }
    await api.commit(subkeyDoc, domain, { useMasterkey: true })
    return `concrnt-subkey ${subIdentity.privateKey} ${ccid}@${domain} -`
}
