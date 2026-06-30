# Post-Processing webui — BACKLOG

Tämä on **qnap-pvr fork** TVH:n webui-laajennukselle post-processing
tilan visualisointiin ja hallintaan.

**Täyttöohje:**
- Lisää ominaisuudet sopivalle riville (yksi ominaisuus per `FEATURE:` -rivi)
- Pidä kuvaukset tiiviinä (1-2 lausetta, yksi toiminto)
- Älä lisää teknisiä yksityiskohtia tänne — ne kuuluvat suunnitelmatiedostoon

**Osioiden selitys:**
- **DVR** — Digital Video Recorder -välilehti
  (Tallennukset, post-recording -asetukset, ajastukset)
- **CFG** — Configuration-välilehti
  (comskip/transcode -asetukset, profiilit, kanavalistat, post-processing)
- **STS** — Status-välilehti
  (post-processing -tilastot, jonot, lokit, virheet)
- **SYS** — Cross-cutting / infra
  (tietoturva, suorituskyky, ylläpito)

**WSJF-arvioinnin kentät (täytetään myöhemmin):**
- **BV** — Business Value (1-13 fibonaccilla)
- **TC** — Time Criticality (1-13)
- **RR/OE** — Risk Reduction / Opportunity Enablement (1-13)
- **Job size** — 1, 2, 3, 5, 8, 13
- **WSJF** = (BV + TC + RR/OE) / Job size

---

## DVR — Digital Video Recorder

- **Feature**: Digital Video Recorder menun alle oma Post Processing välilehti
- **Feature**: post-processing tehtävien status ja hallinta samalla logiikalla kuin mitä tallenteille voi oman valikkonsa alta tehdä: list view, rivi per item, comskip ja transcode jono, prosessoinnissa oleva file & status ja onnistuneesti/virheeseen päätyneet ajot. statustiedon (pending, processing, done, fail) voi näyttää rivin tiedoissa esim. sopivalla ikonilla.
- **Feature**: PP itemin valitsemalla saa tallenteen lisätiedot (esim. video/audio/subtitle formaatit as-is .ts tiedostossa ja to-be .mp4 tiedostossa, käytetty/käytettävä transkoodausprofiili, tunnistetut mainoskatkot, jne.)
- **Feature**: Jonossa odottavan jobin transkoodausprofiilin voi valita itemin lisätiedoissa
- **Feature**: Virheeseen päätyneiden ajojen lisätiedoista voi valita "Retry", jolloin item siirtyy takaisin jonoon (ja sen lisätietoja, esim. transkoodausprofiilia, voi muokata ennen ajon käynnistymistä)

## CFG — Configuration

- **Feature**: Configuration päävalikon alle oma Post Processing välilehti ja sen alle valikot Comskip ja Transcode.
- **Feature**: Comskip valikon UI buildataan comskip.ini ja comskipin config.yaml pohjalta. Mahdollisuus muokata arvoja TVH webui kautta ja muutokset tallentuvat tiedostoihin. Comskip lukee automaattisesti päivitetyt asetukset heti seuraavan comskip-jobin käynnistyessä.
- **Feature**: Transcode valikon alle samalla tavalla UI, joka näyttää konfiguroidut transkoodausasetukset ja output folderin yms. konfiguraatioasetukset. Transcode lukee päivitetyt asetukset heti seuraavan transkoodausjobin käynnistyessä.

## STS — Status

- **Feature**: Oma välilehti Status menu alle. Post Processing status (read only) Comskip ja Transcode osalta.

## SYS — System / Cross-cutting

---

# WSJF-analyysi

Arviointiasteikko: fibonacci 1, 2, 3, 5, 8, 13
- **BV** = Business Value (miten paljon käyttäjä hyötyy)
- **TC** = Time Criticality (kuinka tärkeää saada pian)
- **RR/OE** = Risk Reduction / Opportunity Enablement
  - RR: kuinka paljon vähentää TVH:n rikkoontumisriskiä
  - OE: kuinka paljon avaa uusia mahdollisuuksia
- **Job size** = 1 (pieni, <1h) → 13 (iso, >1 viikko)
- **WSJF** = (BV + TC + RR/OE) / Job size

## Feature-arviot

| # | Osiot | Feature | BV | TC | RR/OE | Sum | Job | WSJF |
|---|-------|---------|---:|---:|------:|----:|----:|-----:|
| **D1** | DVR | Post-Processing välilehti (menu-rakenne) | 13 | 8 | 3 | 24 | 2 | **12.0** |
| **D2** | DVR | PP-jonot + status (read-only lista) | 13 | 13 | 5 | 31 | 3 | **10.3** |
| **D3** | DVR | Itemin lisätiedot (formaatit, profiili, EDL) | 8 | 5 | 3 | 16 | 3 | **5.3** |
| **D4** | DVR | Profiilin valinta itemille | 5 | 3 | 5 | 13 | 3 | **4.3** |
| **D5** | DVR | Retry epäonnistunut (nappi) | 5 | 5 | 3 | 13 | 2 | **6.5** |
| **C1** | CFG | Post-Processing menu + Comskip/Transcode | 8 | 5 | 2 | 15 | 1 | **15.0** |
| **C2** | CFG | Comskip UI (config-edit) | 8 | 5 | 5 | 18 | 5 | **3.6** |
| **C3** | CFG | Transcode UI (config-edit) | 8 | 5 | 5 | 18 | 5 | **3.6** |
| **S1** | STS | Status välilehti (read-only KPI) | 5 | 3 | 3 | 11 | 2 | **5.5** |

## WSJF-järjestys (suurin ensin)

1. **C1** — 15.0 (CFG Post-Processing menu + Comskip/Transcode)
2. **D1** — 12.0 (DVR Post-Processing välilehti)
3. **D2** — 10.3 (DVR PP-jonot + status)
4. **D5** — 6.5 (DVR Retry)
5. **S1** — 5.5 (STS Status välilehti)
6. **D3** — 5.3 (DVR Itemin lisätiedot)
7. **D4** — 4.3 (DVR Profiilin valinta)
8. **C2** — 3.6 (CFG Comskip UI)
9. **C3** — 3.6 (CFG Transcode UI)

## Riippuvuudet

```
D1 ──► D2 (välilehdellä ei ole sisältöä ilman jono-näkymää)
       │
       ├──► D3 (itemin tiedot ovat lisäys jononäkymään)
       │        │
       │        └──► D4 (profiilin valinta on D3:n alidialogi)
       │
       └──► D5 (retry-nappi on D3/D2-osio, mutta tarvitsee D3)

C1 ──► C2 (Comskip UI tarvitsee CFG-valikon kontekstin)
       └──► C3 (Transcode UI samoin)

S1 on itsenäinen (status-välilehti)
```

Kriittinen polku: **C1 → D1 → D2**

## Feature Pack -ehdotus

WSJF:n ja riippuvuuksien perusteella muodostan 4 feature packia:

### FP-1: Perusta (WSJF-painotettu korkeimmalle)
- **Sisältö**: C1 + D1 + D2
- **Laajuus**: Menu-rakenne paikoilleen (CFG + DVR), PP-jonot näkyvät read-only -muodossa
- **Käyttäjäkokemus**: Operaattori näkee molemmat jonot selaimessa, mutta ei voi muokata mitään
- **TVH-fork laajuus**: pienin mahdollinen — vain `http_path_add` rekisteröinnit ja JSON-palautus
- **Riippuvuudet**: ei mitään (perusta kaikelle muulle)
- **Riskitaso**: matala (read-only)
- **WSJF-summa**: 37.3 (12.0 + 15.0 + 10.3)

### FP-2: Toiminnot (write)
- **Sisältö**: D5 + S1 + D3
- **Laajuus**: Retry-nappi (D5), Status-näkymä (S1), Itemin lisätiedot -dialogi (D3)
- **Käyttäjäkokemus**: Operaattori voi retrytä epäonnistuneita, tarkastella yhteenvetoa, avata item-lisätietoja
- **TVH-fork laajuus**: lisää POST `/pvr/api/retry`, Status-moduulin laajennus, dialogi
- **Riippuvuudet**: FP-1 (D2:n päällä)
- **Riskitaso**: keskitaso (POST on mutatoiva)
- **WSJF-summa**: 17.3 (6.5 + 5.5 + 5.3)

### FP-3: Profiilin valinta
- **Sisältö**: D4
- **Laajuus**: Item-lisätiedoissa voi vaihtaa profiilia ennen ajoa
- **Käyttäjäkokemus**: Operaattori voi valita nopean web_720p:n tärkeälle tallenteelle, preservation oletuksena
- **TVH-fork laajuus**: POST `/pvr/api/profile` + dialogin lomake
- **Riippuvuudet**: FP-2 (D3:n päällä, joka on FP-1:n päällä)
- **Riskitaso**: keskitaso
- **WSJF-summa**: 4.3

### FP-4: Konfiguraation editointi
- **Sisältö**: C2 + C3
- **Laajuus**: Comskip ja Transcode -asetusten muokkaus TVH-webui:sta
- **Käyttäjäkokemus**: Ei tarvitse enää ssh:ta konfigin muuttamiseen
- **TVH-fork laajuus**: GET/PUT `/pvr/api/config/<name>`, monimutkaisin yksittäinen ominaisuus
- **Riippuvuudet**: FP-1 (C1:n päällä, ei FP-2:ta)
- **Riskitaso**: korkea (config.vioittuminen vaikuttaa kaikkiin tuleviin ajoihin)
- **WSJF-summa**: 7.2 (3.6 + 3.6)

## Suositus: Toteutusjärjestys

**FP-1 → FP-2 → FP-4 → FP-3**

WSJF-perustainen järjestys, jossa:
1. **FP-1** tuottaa välittömästi hyötyä (näkyvyys) pienellä riskillä
2. **FP-2** lisää toiminnot FP-1:n päälle
3. **FP-4** tehdään ennen FP-3:aa, koska se on itsenäinen eikä riipu FP-2:sta, ja konfig-edit on konfiguraation muutos joka kannattaa saada aikaisin
4. **FP-3** viimeisenä, koska profiilin valinta on pienempi arvo

**Huomautus**: Käyttäjä on aiemmin sanonut haluavansa Plan B:n (TVH-fork). Tämä pakettijako on yhteensopiva Plan B:n kanssa. Jokainen FP on yksi commit, reversiibeli, ja voidaan testata erikseen.
