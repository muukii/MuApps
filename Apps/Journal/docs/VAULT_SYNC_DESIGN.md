# Journal Vault Sync 設計

この文書は、Journal の永続化と collaboration の目標設計を記録するためのもの。
`SPECIFICATION.md` は現在のアプリ仕様を記述し、この文書はこれから作る
target architecture を扱う。

## 方向性

Journal では SwiftData の managed CloudKit mirroring を使わない。
SwiftData は local persistence と SwiftUI からの observation のための layer として扱う。

CloudKit collaboration はアプリ側の sync layer が所有する。
その layer が local SwiftData model と CloudKit record の対応付け、
`CKShare` の作成と受け入れ、remote change の import を担当する。

Shared with You は sync layer ではなく、Messages、FaceTime、share sheet、
system collaboration UI と接続する presentation / integration layer として使う。
Journal の data authority は CloudKit と `VaultSyncEngine` に置き、
Shared with You は「共有を Apple platform 上で collaboration として見せる」ために使う。

重要な境界は次の形になる。

```text
SwiftUI
  observes
VaultInstance
  owns one local vault database
CloudKit sync coordinator
  maps to and from
CloudKit zone / CKShare
Shared with You
  presents collaboration entry points
```

```mermaid
flowchart LR
  SwiftUI["SwiftUI views"]
  Runtime["JournalVaultRuntime<br/>selectedVault"]
  VaultInstance["VaultInstance(vaultID)"]
  CatalogStore["VaultCatalogStore<br/>ModelContainer"]
  ContentStore["VaultContentStore(vaultID)<br/>ModelContainer"]
  SyncEngine["CloudKit sync coordinator<br/>CKSyncEngine per database scope"]
  CloudKitZone["CloudKit custom zone"]
  Share["CKShare"]
  SharedWithYou["Shared with You<br/>Messages / FaceTime / Share Sheet"]

  SwiftUI --> Runtime
  Runtime --> VaultInstance
  Runtime --> CatalogStore
  VaultInstance --> ContentStore
  VaultInstance --> SyncEngine
  SyncEngine --> CloudKitZone
  CloudKitZone --> Share
  Share --> SharedWithYou
```

## 実装方針

この作り替えは UI rewrite ではなく、まず persistence / sync foundation の
作り替えとして進める。UI は新しい vault store と sync state が安定してから、
vault picker、toolbar、settings、collaboration view の順で調整する。

実装 task の管理は `VAULT_TASKS.md` で行う。ここでは architecture と境界を記述し、
どの task を誰がいつ触るか、並行作業の file ownership、Done 条件は task document に寄せる。

最初の milestone は次の 2 点に集中する。

1. SwiftData の CloudKit mirroring を vault store では完全に無効化する。
2. CloudKit との同期は `VaultSyncEngine` が所有する明示的な sync layer として作る。

app shell の user-facing save / read UI は `VaultInstance` を使う。
`VaultInstance` は 1 vault の local database、media directory、sync/outbox status、
permission/share state、vault-scoped action を UI に見せる domain object とする。
内部では `VaultContentStore` を所有するが、画面は CloudKit transport object を直接持たない。
旧 `JournalModel` store は app shell の startup path では開かない。
legacy data migration は CloudKit query / write operation として sync layer が所有し、
SwiftUI tree には legacy `ModelContainer` を注入しない。
`cloudKitDatabase: .automatic` を前提にした model constraint、widget query、
media sync の分離設計は target architecture に順次移行する。

```mermaid
flowchart LR
  View["SwiftUI views"]
  Instance["VaultInstance"]
  Store["VaultContentStore<br/>SwiftData / cloudKit: none"]
  Metadata["SyncMetadata<br/>recordID / zoneID / changeTag"]
  Outbox["PendingMutation"]
  Sync["CloudKit sync coordinator"]
  CloudKit["CloudKit<br/>private/shared CKDatabase"]

  View --> Instance
  Instance --> Store
  Instance --> Sync
  Store --> Metadata
  Store --> Outbox
  Outbox --> Sync
  Metadata --> Sync
  Sync --> CloudKit
  CloudKit --> Sync
  Sync --> Store
```

画面は CloudKit を直接読まない。
画面は SwiftData を local truth として observe し、`VaultSyncEngine` が
remote changes を import した結果として SwiftData が更新される。

`CKRecord` は local persistence ではなく transport shape として扱う。
local model 側には `CKRecord` を丸ごと保存するのではなく、
record ID、zone ID、change tag、encoded system fields など、再送信と
conflict resolution に必要な metadata を保持する。

## 既存 SyncEngine の扱い

旧 `MediaSyncEngine` は app shell から削除済みで、最終形には残さない。
その責務は `VaultSyncEngine` に吸収する。

旧 architecture では SwiftData CloudKit mirroring が `Card` / `Attachment` row を同期し、
`MediaSyncEngine` が attachment file / `CKAsset` を別 zone で補助同期している。
これは legacy architecture のための bridge だったため、app shell の save / list が
vault store へ移った時点で削除した。

target architecture では、vault store は `cloudKitDatabase: .none` で作り、
`VaultSyncEngine` が row、asset、zone、`CKShare`、subscription、remote change import を
vault boundary の中でまとめて扱う。shared vault でも row と media は同じ shared zone に
含めるため、participant が row だけを受け取り、media file だけ別 boundary から待つ形にしない。

```mermaid
flowchart LR
  subgraph Legacy["Migration source only"]
    LegacyStore["JournalModel<br/>SwiftData CloudKit mirroring"]
    MediaSync["MediaSyncEngine<br/>file / CKAsset sync only"]
    LegacyStore --> MediaSync
  end

  subgraph Target["Target vault architecture"]
    VaultStore["VaultContentStore<br/>SwiftData / cloudKit: none"]
    VaultSync["VaultSyncEngine<br/>row + asset + share sync"]
    Zone["CloudKit vault zone<br/>records + CKAsset + CKShare"]
    VaultStore --> VaultSync
    VaultSync --> Zone
    Zone --> VaultSync
    VaultSync --> VaultStore
  end

  MediaSync -.->|"責務を吸収して削除"| VaultSync
```

`MediaSyncEngine` を消す条件として次の境界を置いた。

1. app shell の save / read が selected `VaultInstance` 経由で `VaultContentStore` を使う。
2. attachment row と media file が vault directory 配下に保存される。
3. asset upload / download と file availability signal が `VaultSyncEngine` 経由になる。
4. widget / global view が `VaultCatalogStore` の summary を読む。
5. CloudKit query / write migration または export / import により旧 data からの移行手段がある。

`SyncStatusMonitor` も同じ境界で置き換える。
旧実装の SwiftData mirroring と `MediaSyncEngine` queue を監視する UI ではなく、
CloudKit sync coordinator と `VaultInstance` の upload / download / conflict / share state と
`VaultCatalogStore` の vault summary を見る UI にする。

2026-07 の app shell 移行では、1、2、3、5 を先に満たした。
`MediaSyncEngine` / `SyncStatusMonitor` / 旧 sync status UI は削除済み。
production runtime は `CloudKitVaultSyncEngine` を使う。`LoggingVaultSyncEngine` は
preview / debug / narrow tests 用の network-less stub として残す。
4 は widget migration の次フェーズで行う。

## Vault

Vault は durable な collaboration boundary。
アプリ内に複数作れるようにする。

- 完全個人用
- 友達と
- パートナーと

各 vault は local SQLite store と SwiftData `ModelContainer` を個別に持つ。
local persistence の意味では `Vault == store.sqlite == ModelContainer == VaultContentStore`。
CloudKit content boundary の意味では `Vault == custom record zone`。
shared vault の場合は、その zone を他の iCloud user と共有する。
CloudKit transport database の意味では `Vault != CKDatabase`。
owned vault は current user's private database の zone、participant として参加した vault は
current user's shared database から見える zone になる。
personal vault は特別な data model ではなく、まだ `CKShare` が作られていない vault として扱う。

```text
Journal/
  catalog.sqlite
  Vaults/
    <vault-id>/
      store.sqlite
      media/
      sync-state/
```

この分割により、削除、reset、export、invite acceptance、conflict recovery を
vault 単位に閉じ込められる。

## Store 分割

永続化は 2 段に分ける。

```text
VaultCatalogStore
  VaultIndex
  VaultLocalState
  VaultSummary

VaultContentStore(vaultID)
  VaultInfo
  CardEdge
  Card
  Attachment
  SyncMetadata
  PendingMutation
```

```mermaid
flowchart TB
  subgraph Catalog["VaultCatalogStore"]
    VaultIndex["VaultIndex"]
    VaultLocalState["VaultLocalState"]
    VaultSummary["VaultSummary"]
  end

  subgraph Personal["VaultContentStore: Personal"]
    PersonalDB["store.sqlite"]
    PersonalMedia["media/"]
    PersonalSync["sync-state/"]
  end

  subgraph Friends["VaultContentStore: Friends"]
    FriendsDB["store.sqlite"]
    FriendsMedia["media/"]
    FriendsSync["sync-state/"]
  end

  subgraph Partner["VaultContentStore: Partner"]
    PartnerDB["store.sqlite"]
    PartnerMedia["media/"]
    PartnerSync["sync-state/"]
  end

  VaultIndex --> Personal
  VaultIndex --> Friends
  VaultIndex --> Partner
  VaultSummary --> Personal
  VaultSummary --> Friends
  VaultSummary --> Partner
```

`VaultCatalogStore` は小さな catalog store。
vault picker、launch routing、widget summary、local-only preference を支える。
card content は持たない。

`VaultContentStore` は 1 つの vault の card content を所有する store。
SwiftData model instance は別の vault container にまたがって持ち回らない。
vault 間で content を移動する場合、それは relationship の移動ではなく export/import として扱う。

`VaultInstance` は UI が触る vault の domain object。
1 つの `VaultContentStore`、foreground sync interest、outbox count、permission/share state、
vault-scoped actions を束ねる。`VaultInstanceRegistry` は process 内で vault ごとに
stable な `VaultInstance` を返し、`VaultStoreRegistry` はその内側で vault ごとに
単一の `ModelContainer` を保証する。

以前話していた `JournalIndexStore` はここでいう `VaultCatalogStore`、
`VaultStore` はここでいう `VaultContentStore` に相当する。

## CloudKit Sync

Vault 用の store では SwiftData CloudKit mirroring を無効化する。

```swift
ModelConfiguration(
  schema: vaultSchema,
  url: vaultStoreURL,
  cloudKitDatabase: .none
)
```

custom sync layer は次を所有する。

- owned vault ごとの CloudKit zone 作成
- shared vault 用の `CKShare(recordZoneID:)` 作成
- share invitation の受け入れ
- owner 側の private database sync
- participant 側の shared database sync
- record system fields と change token
- pending upload / delete queue
- conflict policy
- asset upload / download
- read-only participant の permission handling

sync metadata は vault store の中に置く。
これにより、vault ごとの reset や repair を独立して実行できる。

CloudKit sync coordinator は app lifetime の service として起動し、private database 用と
shared database 用の sync path を分ける。`CKSyncEngine` を採用する場合、
engine は vault ごとではなく CloudKit database scope ごとに持つ。
engine state はアプリが disk に永続化する。

起動時には毎回 CloudKit vault recovery / reconciliation を kick する。
これは重い migration ではなく、local catalog と CloudKit 上の visible vault zones を
照合する lightweight repair path。

1. private database の Journal vault zones を enumerate し、missing catalog row を
   owned vault として materialize する。
2. shared database の accepted shared zones を enumerate し、missing catalog row を
   participant vault として materialize する。
3. zone-wide share は `CKRecordZone.share` または `CKRecordNameZoneWideShare` の
   `CKShare` record fetch で再発見し、local summary を補正する。
4. materialize 後は `CKSyncEngine.fetchChanges(.all)` を kick して通常 import path に戻す。

この recovery は UI を block しない。iCloud account unavailable、network failure、
CloudKit server error は non-fatal として記録し、次回起動または手動 refresh で再試行する。
毎回 full record import / CKAsset download をやり直すのではなく、catalog 欠落と
engine state 欠落を self-heal するのが目的。

recovery 後も CloudKit 上に visible vault がなく、local catalog も空の場合は、
onboarding 未完了なら新規 user onboarding、onboarding 完了済みなら空の vault picker を表示する。
preset vault は自動作成しない。user が最初の vault を作った時点で local catalog row、
vault store、CloudKit outbox が作られる。

Root screen routing は、fresh install だけ blocking Loading から始める。
初回は `JournalVaultRuntime.resolveInitialVaultAvailability()` を待ち、
iCloud available なら private / shared database の初回 vault discovery を行う。
iCloud no account / restricted では local-only state として resolution を完了し、
CloudKit を使っていない user を Loading に閉じ込めない。
iCloud temporarily unavailable、account status could not determine、network failure では
deferred CloudKit recovery として resolution を完了し、次回以降の background sync / recovery に任せる。
resolved decision 後に `hasResolvedInitialVaultAvailability` を保存する。
次回以降はこの cached decision と `hasCompletedOnboarding` から即座に route を復元し、
`JournalVaultRuntime.start()` / background CloudKit sync は毎回走らせる。
`hasCompletedOnboarding` は「vault が存在しない user に onboarding を再表示するか」を決める
補助 flag であり、既存 vault / recovered vault がある user を onboarding に戻す primary gate ではない。

```mermaid
flowchart TD
  Root["RootView"]
  Cache{"Initial vault availability resolved?"}
  Loading["Loading<br/>resolve initial vault availability"]
  CachedRoute["Restore cached route immediately"]
  Resolve["resolveInitialVaultAvailability"]
  CloudKit["iCloud available<br/>fetch private + shared vault changes"]
  LocalOnly["iCloud unavailable<br/>resolve local-only state"]
  Runtime["Start vault runtime + background sync"]
  Existing["Existing user flow"]
  NewUser["New user onboarding"]
  Picker["VaultSelectionView"]
  Creation["CreationView"]

  Root --> Cache
  Cache -->|"no"| Loading
  Cache -->|"yes"| CachedRoute
  CachedRoute -->|"onboarding completed"| Existing
  CachedRoute -->|"onboarding not completed"| NewUser
  Loading --> Resolve
  Resolve -->|"available"| CloudKit
  Resolve -->|"no account / restricted"| LocalOnly
  Resolve -->|"temporary unavailable / network error"| Deferred["Deferred CloudKit recovery"]
  CloudKit --> Runtime
  LocalOnly --> Runtime
  Deferred --> Runtime
  CachedRoute -.-> Runtime
  Runtime -->|"local or recovered vaults exist"| Existing
  Runtime -->|"no vaults and onboarding not completed"| NewUser
  Runtime -->|"no vaults but onboarding completed"| Existing
  Runtime -->|"resolved"| Decision["Save hasResolvedInitialVaultAvailability"]
  NewUser -->|"complete onboarding"| Existing
  Existing --> Picker
  Picker -->|"select or create vault"| Creation
  Creation -->|"change vault"| Picker
```

subscription は画面ごとに作らない。
CloudKit subscription は sync layer が idempotent に作る durable infrastructure とし、
vault 画面を開くことは foreground sync interest として扱う。

```text
Vault screen opened
  -> VaultSyncCoordinator.activate(vaultID)
  -> fetchChanges / sendChanges を明示的に kick
  -> selected vault の asset download と conflict handling を優先
  -> imported changes が VaultContentStore に merge される
  -> SwiftUI が SwiftData observation で更新される
```

private database の owned vault では custom zone subscription を使える。
shared database の participant vault では record zone subscription を使えないため、
shared database subscription と change fetch のあとに zone ID で vault を振り分ける。

```mermaid
sequenceDiagram
  participant OwnerApp as Owner app
  participant OwnerStore as Owner VaultContentStore
  participant OwnerSync as Owner VaultSyncEngine
  participant CloudKit as CloudKit zone
  participant ParticipantSync as Participant VaultSyncEngine
  participant ParticipantStore as Participant VaultContentStore

  OwnerApp->>OwnerStore: Save CardEdges, Cards, Attachments
  OwnerSync->>OwnerStore: Read pending mutations
  OwnerSync->>CloudKit: Upload records and assets
  OwnerApp->>OwnerSync: Share vault
  OwnerSync->>CloudKit: Create CKShare(recordZoneID)
  ParticipantSync->>CloudKit: Accept share metadata
  ParticipantSync->>CloudKit: Fetch shared zone changes
  ParticipantSync->>ParticipantStore: Import records and assets
```

## Shared with You / Messages 連携

Shared with You は、vault を Messages の会話や FaceTime の collaboration surface と結び付けるために使う。
CloudKit が data / permission / sync を担当し、Shared with You が share sheet、preview、
participant UI、Messages thread notice を担当する。

```mermaid
flowchart TB
  VaultScreen["Vault settings / toolbar"]
  ShareEntry["ShareLink or UIActivityViewController"]
  ItemProvider["NSItemProvider / CKShareTransferRepresentation"]
  CKShare["CKShare for vault zone"]
  CollaborationView["SWCollaborationView"]
  Observer["CKSystemSharingUIObserver"]
  Highlight["SWHighlightCenter / SWHighlightEvent"]
  Messages["Messages / FaceTime"]
  CatalogStore["VaultCatalogStore"]

  VaultScreen --> ShareEntry
  ShareEntry --> ItemProvider
  ItemProvider --> CKShare
  CKShare --> CollaborationView
  CollaborationView --> Messages
  Observer --> CatalogStore
  Highlight --> Messages
```

採用する API の役割は次の通り。

- `NSItemProvider.registerCKShare(...)` または `CKShareTransferRepresentation` で、
  vault の `CKShare` を collaboration object として share sheet に渡す。
- `UIActivityItemsConfiguration` / `LPLinkMetadata`、または SwiftUI の `SharePreview` で、
  Messages や share sheet に出る vault preview の title と image を提供する。
- `SWCollaborationView(itemProvider:)` を vault toolbar または vault settings に置き、
  participant 表示、`activeParticipantCount`、Manage Share UI への入口を提供する。
- `CKSystemSharingUIObserver` で、system sharing UI 経由の share save / stop sharing を observe し、
  `VaultCatalogStore` の share state を更新する。
- `SWHighlightCenter` と `SWHighlightEvent` 系を使い、必要に応じて Messages thread に
  content update、mention、rename/delete、membership update の notice を post する。

`CKSystemSharingUIObserver` は remote record changes の observer ではない。
他の participant が card を編集した、attachment が増えた、という変更は
`VaultSyncEngine` が CloudKit remote changes として取り込む。
`CKSystemSharingUIObserver` は local device 上の system sharing UI が `CKShare` を
save / delete した結果を local state に反映するためのもの。

`VaultCatalogStore` には Shared with You 用の summary state を持たせる。

```text
VaultSummary
  vaultID
  title
  isShared
  shareURL?
  shareRecordName?
  participantCount
  permissionSummary
  lastSharedWithYouNoticeAt?
```

最初に対応する範囲は、share sheet preview、`SWCollaborationView`、share save / stop sharing の反映まで。
Messages thread への update notice は、content edit の粒度と notification policy が固まってから入れる。

## Card Tree

`CardGroup` のような non-card root は、core posting model には持ち込まない。
Journal の content は、root も child も同じ shape の `CardEdge` として扱う。

GraphQL / Relay 的には、`CardEdge` が `node: Card` と edge metadata を持つ。
UI 上は `CardEdge { card, children }` の recursive tree として組み立てる。
永続化では `children` 配列を直接保存せず、`parentEdgeID` から導出する。

```text
Vault
  root CardEdge
    card
    children: [CardEdge]
  root CardEdge
    card
    children: [CardEdge]
```

target model では `CardRelationship` を廃止する。
thread / continuation / latest item の意味は `CardEdge` で表現する。
linear sequence では root edge と child edge を `sortIndex` で並べる。
mind map の branch は `CardEdge.parentEdgeID` と layout metadata で表現する。
これにより、root だけ `CardGroup` になる不自然さを避けつつ、
任意 graph の merge、cycle 解決、relationship duplicate 解決を sync layer から外せる。

`Card` は本文と attachment を持つ content atom。
`CardEdge` はその card が vault tree 内のどこに置かれるかを表現する placement edge。
root card も child card も、必ず 1 つの `CardEdge` を通して表示される。

CloudKit には `CardEdge.parentEdgeID` を通常の field として保存する。
必要なら `CKRecord.Reference(action: .none)` にしてもよいが、sharing boundary のために
`CKRecord.parent` は使わない。
削除 cascade、subtree move、cycle validation、latest item の解釈は
CloudKit の record hierarchy ではなく domain rule として扱う。

将来「この card が別の card を参照している」「この card への reply を作る」のような
意味的な link が必要になった場合は、tree topology とは別の `CardLink` として追加する。
`CardEdge` は placement / ordering 用、`CardLink` は semantic cross-link 用として分ける。

```text
CardEdge
  id
  cardID
  parentEdgeID?
  sortIndex
  layout?
  createdAt
  updatedAt

Card
  id
  kind
  body
  createdAt
  updatedAt
  location?

Attachment
  id
  cardID
  kind
  localRelativePath?
  metadata
```

```mermaid
erDiagram
  VAULT_INFO ||--o{ CARD_EDGE : contains
  CARD_EDGE ||--o{ CARD_EDGE : nests
  CARD ||--|| CARD_EDGE : placed_by
  CARD ||--o{ ATTACHMENT : owns

  VAULT_INFO {
    uuid id
    string title
  }

  CARD_EDGE {
    uuid id
    uuid cardID
    uuid parentEdgeID
    int sortIndex
    string layout
    datetime createdAt
    datetime updatedAt
  }

  CARD {
    uuid id
    string kind
    string body
  }

  ATTACHMENT {
    uuid id
    uuid cardID
    string kind
    string localRelativePath
  }
```

概念としては Vault が root `CardEdge` の list を持つ。
root edge は `parentEdgeID == nil`。
child edge は同じ vault 内の parent edge を指す。
ordering、nesting、layout の変更を通常の edge row mutation として扱えるため、
大きな array field を毎回 mutate しなくて済む。

ルールは次の通り。

- すべての visible card は必ず 1 つの `CardEdge` から参照される。
- single-card post は、children を持たない root `CardEdge` として表現する。
- thread-like post は、root `CardEdge` と child edge の authored order で表現する。
- mind-map-like post は、`CardEdge.parentEdgeID` で tree を表現する。
- `CardEdge.parentEdgeID` は同じ vault 内の edge だけを指せる。
- cycle は許可しない。
- cross-vault tree は許可しない。
- cross-tree semantic reference は最初の collaboration design では scope 外にする。
- CloudKit の `CKRecord.parent` は hierarchy sharing 用には使わない。
  vault は zone-wide share なので、共有境界は custom zone が表現する。

この形にすると任意 graph の cycle detection は不要になる。
mind map の cycle validation は `parentEdgeID` の parent chain が同じ vault 内で
自分自身に戻らないことだけを確認すればよい。
また widget の「最新 item」の意味も sequence tree では明確になる。
sequence tree 内の最新 authored item は最後に ordered された edge、
最新 post は最も新しい root edge として扱える。
mind map tree の widget 表示は、root edge の card または tree summary を使う。

## Media

Row と media は同じ vault boundary に閉じる。
participant がある shared boundary から card row だけ受け取り、
media だけ別 boundary から待つ形にはしない。

Media は vault directory 配下の file として保存し、
`VaultSyncEngine` が CloudKit asset として同期する。
shared vault では、`Attachment` record と `CKAsset` が同じ shared zone に含まれる。
participant は shared database から record を受け取り、asset file を自分の local vault directory に保存する。

```text
VaultContentStore
  Attachment row
Vault directory
  media/<attachment-id>
CloudKit zone
  Attachment record + CKAsset
```

UI は引き続き row boundary で live SwiftData model を observe する。
attachment record が local file より先に届いた場合は、
sync layer が file availability の signal を明示的に発火し、
表示中の view が load を retry できるようにする。

## Widget と Global View

Vault は別々の `ModelContainer` に分かれるため、
すべての card を 1 つの `@Query` で横断する global query はできない。

その代わり、`VaultCatalogStore` に denormalized summary を持つ。

- vault ごとの latest root edge / tree
- vault ごとの latest visible card
- unread / activity state
- vault display metadata

Widget はまず `VaultCatalogStore` を読む。
full card content が必要な場合は vault ID から該当する `VaultContentStore` を開ける。
2026-07 時点の widget first pass は `WidgetConfigurationIntent` で vault を選ばせ、
選択された `VaultContentStore` から latest visible card snapshot を直接作る。
将来の default path は小さな summary snapshot を読む形に最適化する。

## 未決定事項

- doodle JSON のような小さな authored data は SwiftData row に直接持つか、attachment asset として扱うか。
- text edit の最初の conflict policy をどうするか。field-wise last write wins、explicit version、append-only replacement のどれに寄せるか。
- `VaultCatalogStore` のうち、どこまでを user 自身の device 間で sync し、どこからを local-only にするか。
- Messages thread に post する Shared with You notice は、どの user action から始めるか。

## 最初の Spike

最小の useful spike は UI の完成ではなく、SwiftData cloudKit off と sync layer の
境界を確実に作ることを目的にする。

Phase 1: Local vault foundation

1. 空の `VaultCatalogStore` を作り、user action で vault row を作れるようにする。
2. vault ごとに separate vault store file を作る。
3. vault store では SwiftData CloudKit mirroring を無効化する。
4. `SyncMetadata` と `PendingMutation` を vault store に置く。
5. network なしの `VaultSyncEngine` protocol と logging stub を実装する。
6. local write が `PendingMutation` に積まれることを確認する。

Phase 2: Content model

1. `CardEdge` と `Card` を作り、すべての save が root edge を生成するようにする。
2. `CardRelationship` の continuation 用途を `CardEdge.parentEdgeID` と `sortIndex` に置き換える。
3. attachment row と media file を vault directory 配下へ移す。
4. active `ModelContainer` を差し替えて UI が vault を切り替えられることを確認する。

Phase 3: CloudKit transport

1. owned vault ごとに custom record zone を作る。
2. `PendingMutation` から `CKRecord` を作って private database に送る。
3. remote changes を fetch して `VaultContentStore` に import する。
4. `CKAsset` を attachment record と同じ vault zone で upload / download する。

Phase 4: Vault lifecycle UI

foundation が固まった後、UI は vault lifecycle を操作する surface として作る。
画面は CloudKit object を直接所有せず、`VaultCatalogStore` の state と
`VaultSyncCoordinator` の action を通して操作する。

1. Vault を切り替える。
   - vault picker / sidebar / menu は `VaultCatalogStore` の `VaultSummary` を読む。
   - 選択された vault は `JournalVaultRuntime.selectedVault` が `VaultInstance` として保持する。
   - `VaultInstance` は `VaultContentStore(vaultID)` を所有し、UI は instance 経由で read/write する。
   - vault を開いたら `VaultInstance.activateForeground()` を呼び、foreground fetch と asset download を優先する。
2. Vault を作る。
   - local catalog row、vault directory、vault content store を作る。
   - 初期状態は unshared vault とし、CloudKit zone と `CKShare` は必要になったタイミングで作る。
   - app install 時に preset vault は作らない。recovery 後に local / remote vault が
     0 件なら、新規 user として空の picker を出す。
3. Vault に招待する。
   - owner 権限の vault だけ invite action を出す。
   - sync layer が vault zone と最小 record を CloudKit に確保し、`CKShare(recordZoneID:)` を作る。
   - share sheet / Shared with You に渡す preview title、image、permission options は vault summary から作る。
   - share save / stop sharing は catalog の share state に反映する。
4. Vault に参加する。
   - app / scene delegate が `CKShare.Metadata` を受け取る。
   - sync layer が share を accept し、shared database の zone view を local catalog row に materialize する。
   - 初回 import が終わったら、その vault を `VaultInstance` として開ける。
   - read-only participant では compose / edit / delete UI を permission state で制限する。

```mermaid
flowchart LR
  Picker["Vault picker"]
  Catalog["VaultCatalogStore"]
  Runtime["JournalVaultRuntime<br/>selectedVault"]
  Instance["VaultInstance"]
  Content["VaultContentStore"]
  Sync["CloudKit sync coordinator"]
  ShareUI["Share / Join UI"]
  CloudKit["CloudKit"]

  Picker --> Catalog
  Picker --> Runtime
  Runtime --> Instance
  Instance --> Content
  Instance --> Sync
  ShareUI --> Sync
  Sync --> Catalog
  Sync --> CloudKit
  CloudKit --> Sync
  Sync --> Content
```

CloudKit zone 作成と owned vault の invite issuance は UI action として接続済み。
`VaultSelectionView` の owned vault row から `VaultSyncEngine.prepareShare(for:)` を呼び、
`CloudKitVaultSyncEngine` が private database の custom zone を保存し、
pending outbox を一度 `CKSyncEngine` へ流したうえで
`CKRecordNameZoneWideShare` を fetch する。既存 share がなければ
`CKShare(recordZoneID:)` を作成して保存し、saved `CKShare` と `CKContainer` を
`UICloudSharingController(share:container:)` に渡す。初期 UI は private invite と
read-write permission に絞り、public link はまだ出さない。

Invite acceptance は SwiftUI app に UIKit scene delegate を差し込み、
running-scene callback と cold-launch `UIScene.ConnectionOptions.cloudKitShareMetadata`
の両方から `CKShare.Metadata` を `JournalVaultRuntime.acceptShare(metadata:)` に渡す。
runtime は `VaultSyncEngine.acceptShare(metadata:)` を通じて share を accept し、
shared database の `CKSyncEngine` に accepted zone 優先の fetch をかける。
fetched zone は既存の shared-zone materialization/import path で local catalog と
vault store に反映される。実 iCloud の二アカウント手動検証はまだ残っている。

Shared With You、collaboration preview / notice は別 milestone。

## Collaboration Spike

CloudKit zone と `CKShare` が作れるようになった後、Shared with You 連携を次の順番で検証する。

1. vault の `CKShare` から collaboration item provider を作る。
2. share sheet に vault preview title / image を出す。
3. Messages に collaboration として送れることを確認する。
4. shared vault の settings または toolbar に `SWCollaborationView` を表示する。
5. `CKSystemSharingUIObserver` で share save / stop sharing を拾い、`VaultCatalogStore` を更新する。
6. owner / participant の permission と `participantCount` の見え方を確認する。
7. content edit notice を 1 種類だけ `SWHighlightChangeEvent` として post するか判断する。

## 実装状況

2026-07 時点。実装は `Sources/JournalVault/`(dynamic framework、
`Tests/JournalVaultTests/` にユニットテスト)。app shell は
`JournalVaultRuntime` / `VaultInstance` を起動し、
Debug-only Settings から catalog、selected vault、outbox depth、debug write を確認できる。
Owned vault invite issuance is implemented through
`VaultSyncEngine.prepareShare(for:)` and `VaultSelectionView`'s system sharing UI
bridge. Invite acceptance is implemented through the scene metadata router,
`JournalVaultRuntime.acceptShare(metadata:)`, and the shared-database
`CloudKitVaultSyncEngine` import path; live two-account acceptance verification
is still pending. Shared With You surfacing and legacy migration are not
implemented in this slice.

起動時には sync engine を start し、毎回 CloudKit vault recovery / reconciliation を
kick する。remote/private/shared vault が見つからず local catalog も空の場合は
新規 user 状態として扱い、空の vault picker を表示する。
app shell は旧 `JournalModel` App Group SQLite を startup migration source として開かない。
legacy migration は `VaultSyncEngine` 側の CloudKit operation として実装する。
旧 CloudKit records / CKAssets を query し、legacy content が見つかった場合だけ
migration target vault zone へ新しい `VaultInfo` / `Card` / `CardEdge` / `Attachment` records を write し、
その後 vault sync import により local `VaultContentStore` へ materialize する。
この migration は target vault の card count が 0 の時だけ実行し、既に content がある
vault へ legacy data を merge しない。
ユーザーが `VaultSelectionView` で vault を選んだ時点で
`JournalVaultRuntime.selectVault(_:)` が `VaultInstance` を開き、
`CreationView` と `SavedListView` はその selected instance だけを使う。

user-facing save は `CreationView` から `VaultInstance.createThread(cards:)` に書く。
user-facing edit は `SavedListView` から selected `VaultInstance` の
`VaultContentStore.updateCard(cardID:with:)` に書く。
user-facing list は selected `VaultInstance` の `CardEdge` / `Card` / `Attachment` snapshot を読む。
旧 saved-entry edit / export share UI、旧 sync status UI、`MediaSyncEngine`、
`SyncStatusMonitor` は削除済み。share / edit は vault-backed UI として作り直す。

実装済み:

- `VaultStoreLayout` — App Group 配下 `Journal/` の directory layout。
- `VaultCatalogStore` + `VaultIndex` / `VaultLocalState` / `VaultSummary`
  (cloudKitDatabase: .none、user-created vault、remote vault の materialize)。
- `VaultContentStore(vaultID)` + `VaultInfo` / `Card` / `CardEdge` /
  `Attachment` / `SyncMetadata` / `PendingMutation`。
  すべての write は同一 transaction で outbox(`PendingMutation`)を積む。
  save は必ず root `CardEdge` を作る。card edit は `Card` save と attachment replacement を
  同一 transaction で扱う。削除 cascade は domain rule として実装。
- `VaultStoreRegistry` — process 内で vault ごとに単一 `ModelContainer` を保証し、
  local mutation を `AsyncStream<VaultID>` で sync layer へ流す。
- `VaultInstanceRegistry` / `VaultInstance` — process 内で vault ごとに stable な
  UI-facing domain object を返す。`VaultInstance` は `VaultContentStore`、
  foreground sync interest、outbox count、将来の permission/share state、
  vault-scoped actions を束ねる。
- `VaultSyncEngine` protocol + `LoggingVaultSyncEngine`(network なしの stub)。
- `CloudKitVaultSyncEngine` — `CKSyncEngine` を private / shared database で
  1 つずつ所有。zone 名に vault ID を埋め込み、fetched changes を zone 名で
  vault へ routing。未知 zone は catalog へ materialize。zone は最初の save が
  `zoneNotFound` を返したときに lazy に作成。engine state は
  `SyncState/{private,shared}-database.json` に永続化。
  `CKAsset` の upload / download(vault の `media/` に保存、
  `VaultMediaFileChange` notification で file 到着を通知)。
- `JournalVaultRuntime` — `JournalApp` 起動時に
  App Group layout、catalog store、store registry、`CloudKitVaultSyncEngine` を作る。
  preset vault は自動作成しない。`previewRuntime()` と debug 用 factory は
  `LoggingVaultSyncEngine` を使い、CloudKit に触らず local vault store を検証できる。
  product UI の selected `VaultInstance` は `VaultSelectionView` の選択で開く。
  Settings の Debug-only `Vault Runtime` 画面から refresh、vault 切り替え、
  debug text card write を実行できる。
- `CreationView` / `SavedListView` — UI は selected `VaultInstance` だけを使う。
  legacy `ModelContainer` は SwiftUI environment に存在しない。

暫定判断(コード側にも記載):

- conflict policy は record 単位で local-pending-wins。
  server の system fields だけ採用して再送する。field-wise merge は未決定のまま。
- remote の record deletion は local edit より優先。
- zone-level deletion(owner の削除 / share revoke)は log のみ。repair flow 未設計。

未実装(次フェーズ):

- `LegacyCloudKitMigration` — 旧 SwiftData mirroring / media sync が作った
  CloudKit records と CKAssets を query し、legacy content が見つかった時だけ
  migration target vault zone へ write する。
  source は local SQLite ではなく CloudKit。target import は `VaultSyncEngine` の
  通常 path に乗せる。
- Shared with You 連携。
- `VaultSummary` の latest card denormalize。
- vault-backed saved-entry export share UI。

## 参考

- [WWDC22: メッセージAppで共同制作の体験を強化する](https://developer.apple.com/jp/videos/play/wwdc2022/10095/)
- [Adding shared content collaboration to your app](https://developer.apple.com/documentation/sharedwithyou/adding-shared-content-collaboration-to-your-app)
- [SWCollaborationView](https://developer.apple.com/documentation/sharedwithyou/swcollaborationview)
- [CKSystemSharingUIObserver](https://developer.apple.com/documentation/cloudkit/cksystemsharinguiobserver)
