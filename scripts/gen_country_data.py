# 规范 ISO 3166-1：alpha2 alpha3 continent(AF/AN/AS/EU/NA/OC/SA)
# 跨洲国家取惯用主归属（RU→EU, TR→AS, KZ→AS, GE/AM/AZ→AS, CY→EU, EG→AF）
DATA = """
AD AND EU
AE ARE AS
AF AFG AS
AG ATG NA
AI AIA NA
AL ALB EU
AM ARM AS
AO AGO AF
AQ ATA AN
AR ARG SA
AS ASM OC
AT AUT EU
AU AUS OC
AW ABW NA
AX ALA EU
AZ AZE AS
BA BIH EU
BB BRB NA
BD BGD AS
BE BEL EU
BF BFA AF
BG BGR EU
BH BHR AS
BI BDI AF
BJ BEN AF
BL BLM NA
BM BMU NA
BN BRN AS
BO BOL SA
BQ BES NA
BR BRA SA
BS BHS NA
BT BTN AS
BV BVT AN
BW BWA AF
BY BLR EU
BZ BLZ NA
CA CAN NA
CC CCK AS
CD COD AF
CF CAF AF
CG COG AF
CH CHE EU
CI CIV AF
CK COK OC
CL CHL SA
CM CMR AF
CN CHN AS
CO COL SA
CR CRI NA
CU CUB NA
CV CPV AF
CW CUW NA
CX CXR AS
CY CYP EU
CZ CZE EU
DE DEU EU
DJ DJI AF
DK DNK EU
DM DMA NA
DO DOM NA
DZ DZA AF
EC ECU SA
EE EST EU
EG EGY AF
EH ESH AF
ER ERI AF
ES ESP EU
ET ETH AF
FI FIN EU
FJ FJI OC
FK FLK SA
FM FSM OC
FO FRO EU
FR FRA EU
GA GAB AF
GB GBR EU
GD GRD NA
GE GEO AS
GF GUF SA
GG GGY EU
GH GHA AF
GI GIB EU
GL GRL NA
GM GMB AF
GN GIN AF
GP GLP NA
GQ GNQ AF
GR GRC EU
GS SGS AN
GT GTM NA
GU GUM OC
GW GNB AF
GY GUY SA
HK HKG AS
HM HMD AN
HN HND NA
HR HRV EU
HT HTI NA
HU HUN EU
ID IDN AS
IE IRL EU
IL ISR AS
IM IMN EU
IN IND AS
IO IOT AS
IQ IRQ AS
IR IRN AS
IS ISL EU
IT ITA EU
JE JEY EU
JM JAM NA
JO JOR AS
JP JPN AS
KE KEN AF
KG KGZ AS
KH KHM AS
KI KIR OC
KM COM AF
KN KNA NA
KP PRK AS
KR KOR AS
KW KWT AS
KY CYM NA
KZ KAZ AS
LA LAO AS
LB LBN AS
LC LCA NA
LI LIE EU
LK LKA AS
LR LBR AF
LS LSO AF
LT LTU EU
LU LUX EU
LV LVA EU
LY LBY AF
MA MAR AF
MC MCO EU
MD MDA EU
ME MNE EU
MF MAF NA
MG MDG AF
MH MHL OC
MK MKD EU
ML MLI AF
MM MMR AS
MN MNG AS
MO MAC AS
MP MNP OC
MQ MTQ NA
MR MRT AF
MS MSR NA
MT MLT EU
MU MUS AF
MV MDV AS
MW MWI AF
MX MEX NA
MY MYS AS
MZ MOZ AF
NA NAM AF
NC NCL OC
NE NER AF
NF NFK OC
NG NGA AF
NI NIC NA
NL NLD EU
NO NOR EU
NP NPL AS
NR NRU OC
NU NIU OC
NZ NZL OC
OM OMN AS
PA PAN NA
PE PER SA
PF PYF OC
PG PNG OC
PH PHL AS
PK PAK AS
PL POL EU
PM SPM NA
PN PCN OC
PR PRI NA
PS PSE AS
PT PRT EU
PW PLW OC
PY PRY SA
QA QAT AS
RE REU AF
RO ROU EU
RS SRB EU
RU RUS EU
RW RWA AF
SA SAU AS
SB SLB OC
SC SYC AF
SD SDN AF
SE SWE EU
SG SGP AS
SH SHN AF
SI SVN EU
SJ SJM EU
SK SVK EU
SL SLE AF
SM SMR EU
SN SEN AF
SO SOM AF
SR SUR SA
SS SSD AF
ST STP AF
SV SLV NA
SX SXM NA
SY SYR AS
SZ SWZ AF
TC TCA NA
TD TCD AF
TF ATF AN
TG TGO AF
TH THA AS
TJ TJK AS
TK TKL OC
TL TLS AS
TM TKM AS
TN TUN AF
TO TON OC
TR TUR AS
TT TTO NA
TV TUV OC
TW TWN AS
TZ TZA AF
UA UKR EU
UG UGA AF
UM UMI OC
US USA NA
UY URY SA
UZ UZB AS
VA VAT EU
VC VCT NA
VE VEN SA
VG VGB NA
VI VIR NA
VN VNM AS
VU VUT OC
WF WLF OC
WS WSM OC
YE YEM AS
YT MYT AF
ZA ZAF AF
ZM ZMB AF
ZW ZWE AF
"""
rows=[r.split() for r in DATA.strip().splitlines()]
assert all(len(r)==3 for r in rows), "bad row"
a2set={r[0] for r in rows}; a3set={r[1] for r in rows}
assert len(a2set)==len(rows)==len(a3set), f"dup: rows={len(rows)} a2={len(a2set)} a3={len(a3set)}"
conts={r[2] for r in rows}
assert conts<= {"AF","AN","AS","EU","NA","OC","SA"}, conts
print("rows:", len(rows), "continents:", sorted(conts))

a3a2="\n".join(f'    "{r[1]}": "{r[0]}",' for r in sorted(rows,key=lambda r:r[1]))
a2cont="\n".join(f'    "{r[0]}": .{ {"AF":"africa","AN":"antarctica","AS":"asia","EU":"europe","NA":"northAmerica","OC":"oceania","SA":"southAmerica"}[r[2]] },' for r in sorted(rows,key=lambda r:r[0]))

swift=f'''//
//  CountryData.swift
//  Carry
//
//  自动生成（scripts/gen_country_data.py），勿手改。ISO 3166-1：
//  alpha-3→alpha-2（storefront 推导 home country 用）+ 国家→大洲（行程册统计用）。
//  跨洲国家取惯用主归属（RU→欧洲，TR/KZ/GE/AM/AZ→亚洲，EG→非洲）。
//

import Foundation

enum Continent: String, CaseIterable {{
    case asia, europe, africa, northAmerica, southAmerica, oceania, antarctica
}}

enum CountryData {{
    /// ISO 3166-1 alpha-3 → alpha-2。storefront 返回 alpha-3，需转 alpha-2。
    static let alpha3ToAlpha2: [String: String] = [
{a3a2}
    ]

    /// alpha-2 → 所属大洲（行程册「大洲分布」统计）。
    static let continentByAlpha2: [String: Continent] = [
{a2cont}
    ]
}}
'''
open("Carry/Models/CountryData.swift","w").write(swift)
print("wrote Carry/Models/CountryData.swift")
