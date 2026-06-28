# Calendar Sync — 行程内事件同步

> **Status: In Progress 🔨**
> 前置：`specs/calendar-sync.md`（已 Shipped）— 本 spec 是其扩展，不替代。

## 目标

现有日历同步只写一条「行程全天事件」。用户在行程规划里添加的 **航班 / 火车等交通段、租车、酒店住宿、有时间的地点**，也应自动同步到系统日历，让用户在日历 App 和 CarPlay 里看到完整的出行安排。

## 产品决策

### 开关策略：复用现有总开关，自动全覆盖

「同步行程到日历」开关开启 → **行程事件 + 所有有时间的行程内事件一并写入**，不加二级子开关。

理由：
- 用户开这个开关的意图是「在日历里看到我的旅行」，分类子开关是信息过载
- CarPlay 场景下希望所有安排都有，不需要用户再操心
- Tripsy 同策略（整体同步）

Settings 说明文字（`settings.calendar.footer`）更新措辞，提及「含行程内活动」。

### 触发时机：与现有逻辑完全对齐

TripStore 里凡触发 `CalendarManager.shared.updateTrip(trip)` 的地方（已有），新逻辑随之生效——无需新增触发点。`updateTrip` = 先 removeTrip（按 URL 匹配删所有该行程事件）→ 再 addTrip（重写全部）。

### 无时间的事件不写日历

| 实体 | 写日历的条件 |
|------|------------|
| ItineraryStop（地点） | `plannedStartMinutes >= 0` |
| TransportSegment（交通） | `departLocalMinutes >= 0` |
| LodgingStay（住宿）— 全天 | 无条件（有住宿就写全天事件） |
| LodgingStay — 入住定时 | `checkInMinutes >= 0` |
| LodgingStay — 退房定时 | `checkOutMinutes >= 0` |

---

## 事件映射规格

### 1. 行程全天事件（现有，保持不变）

```
标题：✈️ {trip.name}
类型：全天，持续 trip.days 天
notes：{destinationCity}\n{dateRange}（字段非空时）
url：carry://trip/{tripId}
```

### 2. 航班（TransportMode.flight）

```
标题：✈️ {number} {fromCode}→{toCode}
      若 number 空：✈️ {carrier} {fromName}→{toName}
      若都空：✈️ {fromName}→{toName}
类型：定时，startDate = 出发绝对时刻，endDate = 到达绝对时刻
      若 arriveLocalMinutes < 0：endDate = startDate + 1h（占位）
location：{fromName}（出发机场名）
时区：出发地 fromTimeZoneId（缺失 → 行程主时区）
notes 拼接（非空字段逐行）：
  {carrier}（航司）
  {fromName} → {toName}
  Terminal: {fromTerminal} → {toTerminal}（有端子时）
  Seat: {seat}
  Class: {cabinClass 本地化}
  Confirmation: {confirmationCode}
  E-Ticket: {eticketNumber}
  Aircraft: {aircraftType}
  {note}
url：carry://trip/{tripId}
```

### 3. 火车 / 大巴 / 渡轮 / 其他交通

```
标题：{emoji} {number} {fromName}→{toName}
      若 number 空：{emoji} {carrier} {fromName}→{toName}
      若都空：{emoji} {fromName}→{toName}
emoji：train→🚄  bus→🚌  ferry→⛴️  other→🚐
类型：定时，同航班
location：{fromName}（出发站名）
时区：fromTimeZoneId（缺失 → 行程主时区）
notes：
  {carrier}
  {fromName} → {toName}
  {routeName}（线路名，如「京沪高铁」）
  Coach: {coachNumber}  Seat: {seat}
  Class: {seatClass}
  Service: {serviceType}
  Confirmation: {confirmationCode}
  {note}
url：carry://trip/{tripId}
```

### 4. 租车（TransportMode.carRental）

```
标题：🚗 取车 · {fromName}
      若 fromName 空：🚗 {carrier}（租车公司名）
类型：定时，startDate = 取车绝对时刻
      endDate：若 arriveLocalMinutes >= 0 用还车时刻；否则 startDate + 1h（占位）
location：{fromAddress}（有则用地址；空则用 fromName）
时区：fromTimeZoneId（缺失 → 行程主时区）
notes：
  {carrier}（租车公司）
  Vehicle: {vehicleModel}
  Plate: {licensePlate}
  Pickup: {fromName}（取车地点）
  Return: {toName}（还车地点）
  Confirmation: {confirmationCode}
  Phone: {phone}
  {note}
url：carry://trip/{tripId}
```

### 5. 酒店住宿 — 全天跨度事件

```
标题：🏨 {stay.name}
类型：全天，startDate = checkInDay 的午夜，endDate = checkOutDay 的午夜（exclusive）
location：{stay.address}（空则 stay.name）
notes：
  Check-in: Day {checkInDayOrder+1}（若有 checkInMinutes 则附加 HH:mm）
  Check-out: Day {checkOutDayOrder+1}（若有 checkOutMinutes 则附加 HH:mm）
  Confirmation: {confirmationCode}
  Phone: {phone}
  {note}
url：carry://trip/{tripId}
```

### 6. 酒店 — 入住定时事件（checkInMinutes >= 0 时额外写）

```
标题：🏨 入住 · {stay.name}
类型：定时，startDate = checkIn 绝对时刻，endDate = startDate + 1h
location：{stay.address}（空则 stay.name）
时区：stay.timeZoneId（缺失 → 行程主时区）
notes：同全天事件 notes
url：carry://trip/{tripId}
```

### 7. 酒店 — 退房定时事件（checkOutMinutes >= 0 时额外写）

```
标题：🏨 退房 · {stay.name}
类型：定时，startDate = checkOut 绝对时刻，endDate = startDate + 1h
location：{stay.address}（空则 stay.name）
时区：stay.timeZoneId（缺失 → 行程主时区）
notes：同全天事件 notes
url：carry://trip/{tripId}
```

### 8. 地点（plannedStartMinutes >= 0）

```
标题：{emoji} {stop.name}
emoji（按 category）：
  sightseeing → 🏛️
  food        → 🍽️
  activity    → 🎯
  shopping    → 🛍️
  lodging     → 🏨
  other / nil → 📍
类型：定时
  startDate = plannedStartMinutes 绝对时刻
  endDate：stayMinutes > 0 → startDate + stayMinutes；否则 startDate + 1h
location：{stop.address}（空则忽略）
时区：stop.timeZoneId（缺失 → 行程主时区）
notes：
  {stop.address}（有时补充地址）
  Phone: {stop.phone}
  {stop.note}
url：carry://trip/{tripId}
```

---

## 绝对时刻计算

复用 `Itinerary.swift` 中已有的静态方法：

```swift
TransportSegment.itineraryAbsoluteDate(
    tripDeparture: trip.departureDate,
    dayOrder: Int,
    minutes: Int,
    tzId: String
) -> Date?
```

LodgingStay 的入住/退房时刻同用此方法，dayOrder 分别取 `checkInDayOrder` / `checkOutDayOrder`，tzId 取 `stay.effectiveTimeZoneId(trip:)`。

地点同用此方法，dayOrder 取 `stop.day?.sortOrder ?? 0`，tzId 取 `stop.effectiveTimeZoneId(trip:)`。

---

## 实现约束

### URL 标记（关键）

`removeTrip` 靠 `url.absoluteString.contains(tripId.uuidString)` 批量删除该行程的所有日历事件。**所有新写事件必须带 `carry://trip/{tripId}` URL**，否则 removeTrip/updateTrip 无法清掉旧事件，导致重复堆积。

### EKEvent 时区设置

```swift
event.timeZone = TimeZone(identifier: tzId) ?? .current
```

EventKit 用 `event.timeZone` 决定定时事件的展示时区；全天事件不设（isAllDay = true 时系统忽略 timeZone）。

### 全天事件 endDate exclusive

EventKit 全天事件 endDate 是 exclusive（不含当天）。住宿全天事件：

```swift
endDate = Calendar.current.date(byAdding: .day, value: stay.nights, to: checkInMidnight)
```

行程全天事件（已有逻辑）同理，不改。

### 改动范围

**只改 `CalendarManager.swift` 的 `writeEvents(for:to:)` 方法**，追加写入行程内事件。其他所有逻辑（开关、权限、触发时机、removeTrip、updateTrip、addedIds）完全不变。

`writeEvents` 内部结构：

```
1. 行程全天事件（现有）
2. for each ItineraryDay:
     for each TransportSegment（按 departLocalMinutes 排，有时间的先写）:
       写交通事件
     for each ItineraryStop（plannedStartMinutes >= 0）:
       写地点事件
3. for each LodgingStay:
     写住宿全天事件
     若 checkInMinutes >= 0：写入住定时事件
     若 checkOutMinutes >= 0：写退房定时事件
```

每个 EKEvent 独立 `store.save(..., commit: false)`，最后统一 `store.commit()`（减少 IO 次数）。任一单条事件写失败只记日志、不中断其余事件写入。

### 新增 CarryLogger.Event

```swift
case calendarItineraryEventsSaved  = "calendar_itinerary_events_saved"  // 写入成功，context 含事件数
case calendarItineraryEventFailed  = "calendar_itinerary_event_failed"  // 单条失败
```

---

## Settings 文案更新

`settings.calendar.footer` 说明文字更新，提及行程内活动：

| Lang | 旧 | 新 |
|------|----|----|
| en | _(现有文案)_ | Trips and their activities (flights, hotels, and places with a time) are added to a "Carry" calendar. |
| zh-Hans | _(现有文案)_ | 行程及其活动（航班、酒店、有时间的地点）将添加到「Carry」日历中。 |
| zh-Hant | _(现有文案)_ | 行程及其活動（航班、飯店、有時間的地點）將加入「Carry」日曆。 |
| de | — | Reisen und ihre Aktivitäten (Flüge, Hotels, Orte mit Uhrzeit) werden dem „Carry"-Kalender hinzugefügt. |
| es | — | Los viajes y sus actividades (vuelos, hoteles, lugares con hora) se añaden al calendario «Carry». |
| fr | — | Les voyages et leurs activités (vols, hôtels, lieux avec heure) sont ajoutés au calendrier « Carry ». |
| ja | — | 旅行とその活動（フライト、ホテル、時刻が設定された場所）が「Carry」カレンダーに追加されます。 |
| ko | — | 여행과 활동(항공편, 호텔, 시간이 설정된 장소)이 'Carry' 캘린더에 추가됩니다. |
| pt-BR | — | Viagens e suas atividades (voos, hotéis, lugares com horário) são adicionados ao calendário "Carry". |

---

## 不在本次范围

- 双向同步（日历改动回写 Carry）
- 过去行程的行程内事件补写
- 打包提醒事件（独立于本 spec 的现有逻辑，保持不变）
- 行程内事件的子粒度开关（待用户反馈再评估）

---

## 验收清单

- [ ] 日历同步开启，新建含航班的行程 → 日历出现该航班的定时事件（出发→到达时间、出发机场 location）
- [ ] 火车/大巴/渡轮事件正确写入，emoji 对应
- [ ] 租车：取车事件，location 为取车地址
- [ ] 酒店：全天事件横跨整个住宿周期；有 checkIn/checkOut 时间时额外出现定时事件
- [ ] 地点（有 plannedStartMinutes）写入；无时间地点不写
- [ ] 修改航班时间 → 日历事件同步更新（updateTrip 触发）
- [ ] 删除行程 → 该行程所有日历事件（含行程内）全部清除
- [ ] 关闭日历同步 → 再打开 → 行程内事件仍然同步（addedIds 清除后重新 addAllUpcoming）
- [ ] CarPlay 中能看到航班、酒店、地点事件（真机验）
- [ ] 无行程内事件（纯打包清单行程）→ 只写行程全天事件，不报错
