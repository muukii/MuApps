# Thoughts (AmbientLight App)

## Concept

- 端末の画面を単なる照明の代用品ではなく、空間に置く「光の作品」として扱う。
- 画面全体を均一に色で埋めるのではなく、黒い余白の中に、柔らかいが知覚できる境界を持つ光のオブジェクトを置く。
- 抽象的なエフェクト名ではなく、薄明、地平線、残光、空や宇宙の現象など、光が生まれる情景を一つの Scene として編集する。
- Scene の動きは主役にしない。静止、または呼吸に近い非常に遅い変化によって、長く置いておける光にする。
- 鑑賞中は操作 UI を完全に隠し、光と黒い余白だけを残す。

## Feature Idea: Light Painting Scenes

- 最初の `Light Painting` Sceneとして、完全な黒の背景に赤→橙→黄の円形光、HDR rim、有限距離で黒へ戻る外側bloomを描く `Solar Field` を実装した。
- `Solar Field` は既存の全面型animated patternとは分け、外形を静止させたまま内部の対流、coreのdrift、円周を巡る局所flareが呼吸する光の作品として扱う。
- Scene ごとに独自の色、形、光の重なり、境界の柔らかさを持たせる。
- `Solar Field` は既存のMatrix Controlで光の位置を直接動かせる。スケールと角度の直接操作は後続候補とする。
- HDR peakは任意倍率ではなく、その時点でdisplayが利用できるEDR headroomへ自動追従する。必要であれば境界の柔らかさと動きの量を後から調整可能にする。
- 現在の長押しによる Scene switcher と、操作後に UI が消える表示体験は維持する。
- Light Dockから15分・30分・1時間を選べるsleep timerを用意し、終了時は光を消して端末の自動sleepを再び許可する。
- 後続候補として、Scene 固有の ambient sound、外部ディスプレイ／プロジェクター出力を検討する。

## Product Boundary

- iPhone の画面だけでは、壁や天井へ大きな光を投影する物理照明の体験は再現できない。アプリ単体では、自己発光する画面上の `light painting` として成立させる。
- 室内全体へ広げる体験は、AirPlay、外部ディスプレイ、または実際のプロジェクターを使う別の出力経路が必要になる。
- 参考製品の名称、固有のグラデーション、構図、サウンドを直接複製せず、自然現象を光の Scene に変換する考え方だけを取り入れる。

## References

- [Halo Edition](https://www.haloedition.com/)
- [Halo One](https://www.haloedition.com/products/halo-one)
- [Halo Horizon](https://www.haloedition.com/products/horizon)
- [Soundscapes](https://www.haloedition.com/pages/soundscapes)
- [About Halo Edition](https://www.haloedition.com/pages/about)
