# 研究のまとめ：表情・声と、言葉を話せない人の手がかり

このアプリが何を記録し、何を記録しないかを決めるための下調べ。v1.12 の「表情のまとまり」「重なりのできごと」「目を閉じている割合」は、ここに書いたことから決めた。
文言は [`wording-guide.md`](wording-guide.md) に従う。このページでも、アプリ・レポートでも、状態の名前（痛み・発作・眠気など）を本人の状態として言わない。
研究の中の言葉（「痛みの表情」など）は、その研究が何を調べたかを書くときだけ使う。

数値は論文に書かれたもの。対象者と人数を必ず並べて書く（このアプリの本人とは、年齢・障害・場面が違う）。

## 1. MediaPipe の blendshape は FACS の AU ではない
- MediaPipe Face Landmarker の 52 の blendshape（`browDownLeft` など）は、AR・アバターを動かすために作られたもの（Apple ARKit と同じ名前の並び）。
  FACS（Facial Action Coding System）の AU（Action Unit）として、コーダーの判定と照らし合わせて確かめられたものではない。
- だから、このアプリの「AU との対応」は、**名前と顔の筋肉（解剖）からの近似**にすぎない：

  | このアプリの指標 | blendshape | 近い AU（近似） |
  |---|---|---|
  | 眉を寄せる `brow_down` | browDown 左右平均 | AU4（眉を下げ寄せる） |
  | 目のまわりを縮める `orbit` | max(eyeSquint, cheekSquint) の左右平均 | AU6（頬を上げる）・AU7（まぶたを緊張させる） |
  | 鼻・上唇を上げる `nose_lip` | max(noseSneer, mouthUpperUp) の左右平均 | AU9（鼻にしわ）・AU10（上唇を上げる） |
  | 口を結ぶ・横に引く `mouth_tense` | max(mouthPress, mouthStretch) の左右平均 | AU24（唇を押しつける）・AU20（唇を横に引く） |
  | 口角を上げる `mouth_smile` | mouthSmile 左右平均 | AU12 |
  | 頬を上げる `cheek_raise` | cheekSquint 左右平均 | AU6 |
  | 口を開ける `jaw_open` | jawOpen | AU26・AU27 |
  | 目を閉じている | eyeBlink 左右平均 ≥ 0.5 が 0.5秒以上 | AU43 |
- 2026-10-27 のわざと動かす記録では、鼻にしわを寄せても `noseSneer` はずっと 0 だった（`analysis/criteria.json` の changelog）。
  `nose_lip` は `mouthUpperUp` との大きい方を使うので、`noseSneer` が動かない端末・顔でも上唇の動きは入る。
- 1つの blendshape が AU の1つにきれいに対応するとは限らない。「目のまわり」と「頬を上げる」はどちらも cheekSquint を含む（AU6 は笑うときにも、顔をしかめるときにも動く）。

## 2. 研究で見られている表情の動き
- **Prkachin & Solomon（2008）**：肩の痛みのある成人 129人の動画を FACS でコードし、PSPI（Prkachin and Solomon Pain Intensity）を作った。
  痛みと関係していたのは **AU4（眉を下げ寄せる）、AU6/7（目のまわりを縮める）、AU9/10（鼻にしわ・上唇を上げる）、AU43（目を閉じる）**。
  PSPI = AU4 + max(AU6, AU7) + max(AU9, AU10) + AU43。このアプリの「上半分の顔の動きの合計（PSPI 型・研究用）」は、この形をまねた研究用の値（v1.0〜、レポートだけ）。
- 持続する痛みの研究では、表情が出ていたのは**時間の約3割**で、1回あたり**平均約5秒**だった。
  → 表情はずっと続くものではないので、短い時間の窓で「重なったか」を見る（v1.12 の `co_change` の 5秒の窓）。表情が出ていない時間が長いことは「何も無い」ことを意味しない。

## 3. 脳性まひ（CP）と知的障害のある人
- CP と知的障害のある成人では、**安静にしているときから顔の動きが多い**人がいて、弱い変化が普段の表情に埋もれることがある。
  → 集団の平均と比べるのではなく、**本人の普段からの変化（z）**で見る（このアプリの普段・保存した普段）。
- CP では、**ジストニア（意図しない筋肉の緊張）**で `jawOpen`・`eyeBlink`・`mouthPress`・頭の向きが変わることがある。
  → **1つの動きだけでは知らせない**。v1.12 の `co_change` は、まとまりの違う2つ以上の動き（表情どうし、または表情と声）が同じ向きに重なったときだけ1つのできごとにする。
  `jaw_open` は話す・ジストニアでもよく動くので、重なりには入れない。目を閉じている割合も判定には使わず、記録だけにする。

## 4. 言葉を話せない人のための尺度
- **NCCPC-R**（Non-communicating Children's Pain Checklist – Revised）、**PPP**（Paediatric Pain Profile）、**r-FLACC**（revised Face, Legs, Activity, Cry, Consolability）、
  **INRS**（Individualized Numeric Rating Scale）は、どれも**表情だけでなく、声・体の動き・本人固有のサイン**を合わせて見ている。
- **INRS** は、本人をよく知る家族が、その人のサイン（いつもと違う声・動き）を決めて、強さを付ける方法。
  このアプリの「家族の印」（家族が自分の判断で付ける記録）に近い。アプリは家族の判断の代わりにはならず、家族の印の前後に何が記録されていたかを並べる。

## 5. 声
- 重度の知的障害のある成人 **9人**の研究で、痛みの有無で有意な差があったのは **shimmer（声の大きさの揺れ）と発声のパルス数**だけだった。
- **声の高さ（f0）・声の大きさ（dB）が上がることは、痛みに限らない**。興奮・不快なこと全般（負の情動）でも起こる。
  → 声の違いは「声が、いつもより高い」のように事実だけを書き、意味を付けない（今まで通り）。shimmer はまだ求めていない（求めるときは、まずレポートだけで試す）。

## 6. このアプリの知らせ方
- 知らせるのは **事実（何が・どちらに・どれだけ続いたか・いつ）と、家族が過去に付けた印**まで。
- **状態の名前（痛み・発作・眠気など）は出さない**。記録のキー名にも使わない（`pain` などにしない。v1.12 のキーは `orbit`・`nose_lip`・`mouth_tense`・`cheek_raise`・`co_change`・`eyes_closed_ratio`・`asym`）。
- 研究を引くときは、出典と対象者・人数を書く（このページの各項）。

## 7. v1.12 で足したもの（記録とレポートだけ。画面と通知は変えない）
- 表情のまとまり（本人の普段からの z）：眉の緊張 `brow_down`、目のまわり `orbit`、鼻・上唇 `nose_lip`、口・あごの緊張 `mouth_tense`（`jaw_open` は今のまま）、
  `mouth_smile` と `cheek_raise`。左右の差（`brow_down`・`orbit`・`mouth_smile` の 左 − 右、本人から見て）も普段と比べて記録する（判定には使わない）
- 重なりのできごと（`event` の `kind: "co_change"`）：仮の値で、記録を見て決め直す（`analysis/criteria.json` の `co_change`）
- 目を閉じている割合（30秒の窓、`kind: "eyes_closed_ratio"`）：判定には使わない
- 振り返りレポート：重なりのできごとの一覧と、それぞれの前後10秒の家族の印

## 8. v1.15：顔の点の距離
- 実機の記録（前面）で、この人の顔では MediaPipe の blendshape の一部（browDown・cheekSquint・noseSneer・mouthSmile）がほとんど動かなかった。blendshape は AU として確かめられたものではないので、
  顔によって動かないことがある。そこで、478点の位置から距離（眉と目の間・眉頭の間・目の開き・口角の高さ）を求めて、両方を記録する（README の「顔の点の距離」）。
  どちらを判定に使うかは、`analysis/face_check.py` で区間ごとに比べてから決める

## 出典
- Prkachin KM, Solomon PE. The structure, reliability and validity of pain expression: Evidence from patients with shoulder pain. *Pain*. 2008;139(2):267–274.（肩の痛みのある成人 129人、PSPI）
- Breau LM, McGrath PJ, et al. Psychometric properties of the Non-communicating Children's Pain Checklist-Revised. *Pain*. 2002.（NCCPC-R）
- Hunt A, et al. Clinical validation of the Paediatric Pain Profile. *Dev Med Child Neurol*. 2004.（PPP）
- Malviya S, et al. The revised FLACC observational pain tool. *Paediatr Anaesth*. 2006.（r-FLACC）
- Solodiuk JC, et al. Validation of the Individualized Numeric Rating Scale (INRS). *Pain*. 2010.（INRS）
- 持続する痛みで表情が出る時間の割合（約3割、1回 平均約5秒）、CP＋知的障害の成人の安静時の顔の動き、重度知的障害の成人 9人の声（shimmer・パルス数）は、
  このまとめを作るときに渡された研究の要約から書いた。原著の書誌は、論文を確かめて足す（まだ確かめていない）。
- Google. MediaPipe Face Landmarker（blendshape の説明：AR・アバター向け）。
