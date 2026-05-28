# Item Tables

三张物品数据表的完整内容，供梳理与维护使用。

> 图例：🔴 = isAlert（遗漏风险高）｜✈️ = internationalOnly（仅国际行程推荐）

---

## 一、ItemCatalog — 分类挑选

用户在「添加物品 → 分类挑选」Tab 手动浏览勾选的物品库。
源文件：`Carry/Models/ItemCatalog.swift`

### Travel Documents
Passport, ID card, Visa, Hotel booking, Travel insurance, Itinerary, Driver's license, International driving permit, HK & Macao permit, Taiwan permit, Vaccination certificate, Boarding pass, Children's passport / ID, Photo ID copy

### Clothing
Underwear, Socks, T-shirt, Jeans, Long pants, Pajamas, Shirt, Cardigan, Hoodie, Bra, Sports bra, Leggings, Tights, Disposable underwear, Shorts, Dress, Skirt, Hat, Belt, Formal wear, Sweater, Rain jacket, Swimsuit, Nipple covers, Comfortable walking shoes, Flip flops, Sun-protective clothing, Scarf

### Electronics
Phone charger, Charging cable, Portable charger, Smart watch charger, Travel adapter, Car charger, Earphones, Noise-cancelling headphones, Tablet, Laptop, Laptop charger, E-reader, Camera, Camera charger, Pocket camera, Action camera, Drone, Memory card, Selfie stick, Tripod, Power strip, Bluetooth speaker, Portable WiFi device

### Personal Care
Makeup remover / cleansing oil, Cotton pads, Face wash, Face mask, Sheet mask, Face mist, Toner, Serum, Eye cream, Facial oil, Lotion, Moisturiser, Body lotion, Lip balm, Sunscreen, Blotting paper, Hair ties, Comb, Hair straightener, Dry shampoo, Perfume, Dental floss, Toothbrush, Toothpaste, Mouthwash, Shampoo, Conditioner, Body wash, Razor, Nail clippers, Acne patches, Deodorant

### Travel Accessories
Card holder, Wallet, Cash, Crossbody bag, Sunglasses, Umbrella, Water bottle, Travel pillow, Neck pillow, Eye mask, Earplugs, Pen, Packing cubes, Laundry bag, Travel towel, Quick-dry towel, Luggage tag, Luggage lock, Luggage scale, Transit card / app

### Makeup
Primer, Foundation, Concealer, Eyebrow pencil, Mascara, Lipstick / Lip gloss, Eyeliner, Eyeshadow, Blush, Highlighter, Setting powder, Makeup brushes, Makeup sponge, Eyelash curler, False eyelashes, Coloured contacts

### Jewelry
Earrings, Necklace, Ring, Bracelet, Watch, Hair clip

### Health & Wellness
Painkillers, Cold & flu medicine, Stomach medicine, Motion sickness tablets, Antihistamines, Prescription medication, Daily medication, Contact lenses, Disposable face masks, Hand sanitiser, First aid kit, Wet wipes, Eye drops, Throat lozenges, Feminine hygiene products, Vitamin C, Vitamin D, Multivitamins, Probiotics, Melatonin, Anti-diarrhea, Insect repellent, Band-aids, Digestive enzymes, After-sun lotion, Electrolyte tablets

### 名称别名（itemNameAliases）

| 旧名 / 别名 | 规范名 |
|------------|--------|
| Driver's licence | Driver's license |
| Cash (local currency) | Cash |
| Reusable water bottle | Water bottle |
| Portable Bluetooth speaker | Bluetooth speaker |
| Motion sickness pills | Motion sickness tablets |
| Pain relievers | Painkillers |
| Sanitary pads / tampons | Feminine hygiene products |
| Overseas SIM / portable WiFi | Portable WiFi device |
| Colored contacts | Coloured contacts |

---

## 二、SceneItemMap — 场景推荐

每次用户选择场景后自动推荐的物品。baseItems 每次都推荐，场景物品叠加合并。
源文件：`Carry/Models/SceneItemMap.swift`

### Base Items（所有行程）

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Passport | 🔴 | ✈️ |
| Wallet | | |
| Cash (local currency) | | |
| Phone charger | | |
| Underwear | | |
| Socks | | |
| Toothbrush | | |
| Toothpaste | | |
| Deodorant | | |

### 🚗 Road trip

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Driver's license | 🔴 | |
| Car insurance docs | 🔴 | |
| Car charger | 🔴 | |
| First aid kit | 🔴 | |
| Sunglasses | 🔴 | |
| Water bottle | | |
| Snacks | | |
| Nuts | | |
| Foldable chair | | |
| Picnic mat | | |

### ✈️ Long-haul flight

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Passport | 🔴 | ✈️ |
| Neck pillow | 🔴 | |
| Noise-cancelling headphones | 🔴 | |
| Overseas SIM / portable WiFi | | |
| Eye mask | | |
| Earplugs | | |
| Compression socks | | |
| Lip balm | | |
| Water bottle | | |

### 🚢 Cruise

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Passport | 🔴 | ✈️ |
| Boarding pass | 🔴 | |
| Motion sickness tablets | 🔴 | |
| Formal dinner outfit | 🔴 | |
| Travel adapter | 🔴 | ✈️ |
| Swimsuit | | |
| Sunscreen SPF 50+ | | |

### ☀️ Tropical / beach

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Sunscreen SPF 50+ | 🔴 | |
| Sunglasses | 🔴 | |
| Sun hat | 🔴 | |
| Insect repellent | 🔴 | |
| Swimsuit | | |
| Flip flops | | |
| After-sun lotion | | |
| Waterproof bag | | |
| Rash guard | | |
| Swimming goggles | | |
| Light rain jacket | | |

### 🌧 Rainy city

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Umbrella | 🔴 | |
| Waterproof jacket | 🔴 | |
| Waterproof shoes | 🔴 | |
| Waterproof phone case | | |
| Quick-dry towel | | |

### ⛰ High altitude

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Altitude sickness pills | 🔴 | |
| Warm base layer | 🔴 | |
| Sunscreen SPF 50+ | 🔴 | |
| Sunglasses | 🔴 | |
| Water bottle | | |
| Electrolyte tablets | | |
| Thermal socks | | |
| Windproof jacket | | |

### ❄️ Winter / cold

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Thermal underwear | 🔴 | |
| Heavy winter coat | 🔴 | |
| Gloves | 🔴 | |
| Beanie / hat | 🔴 | |
| Scarf | | |
| Hand warmers | | |
| Heat patches | | |
| Thermal socks | | |
| Snow boots | | |

### 💼 Business

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Business cards | 🔴 | |
| Laptop | 🔴 | |
| Laptop charger | 🔴 | |
| Formal shirt / blouse | 🔴 | |
| Formal wear | 🔴 | |
| Dress shoes | 🔴 | |
| Overseas SIM / portable WiFi | | |
| Wrinkle-release spray | | |

### 💻 Remote work

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Laptop | 🔴 | |
| Portable WiFi device | 🔴 | |
| Travel adapter | 🔴 | ✈️ |
| Laptop charger | 🔴 | |
| Noise-cancelling headphones | 🔴 | |
| Portable charger | 🔴 | |
| Earphones | | |
| Power strip | | |

### 👶 Travelling with kids

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Children's passport / ID | 🔴 | |
| Children's medication | 🔴 | |
| Wet wipes | 🔴 | |
| Snacks for kids | 🔴 | |
| Favourite toy / comfort item | 🔴 | |
| Travel board game | | |
| Change of clothes (extra) | | |
| Sunscreen for kids | | |

### 🥾 Hiking / camping

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Hiking boots | 🔴 | |
| First aid kit | 🔴 | |
| Headlamp + batteries | 🔴 | |
| Sunscreen SPF 50+ | 🔴 | |
| Water bottle | 🔴 | |
| Trekking poles | | |
| Trail snacks / energy bars | | |

### 💍 Honeymoon

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Passport | 🔴 | ✈️ |
| Formal wear | 🔴 | |
| Dress shoes | 🔴 | |
| Travel adapter | 🔴 | ✈️ |
| Swimsuit | | |
| Camera / extra memory card | | |
| Bluetooth speaker | | |
| Perfume | | |

### 🎒 Backpacking

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Backpack rain cover | 🔴 | |
| Microfibre towel | 🔴 | |
| Quick-dry clothing | 🔴 | |
| First aid kit | 🔴 | |
| Padlock | 🔴 | |
| Water bottle | | |

### 🏨 City break

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Comfortable walking shoes | 🔴 | |
| Crossbody bag | 🔴 | |
| Portable charger | 🔴 | |
| Photo ID copy | 🔴 | |
| Transit card / app | | |
| Umbrella | | |

### 🌸 On / near period

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Feminine hygiene products | 🔴 | |
| Painkillers | 🔴 | |

### 💊 Daily medication

| 物品 | isAlert | internationalOnly |
|------|---------|-------------------|
| Daily medication | 🔴 | |

---

## 三、SurpriseItemMap — Nice to have

「顺手带一个？」功能推荐的物品，每条带说明文案。
源文件：`Carry/Models/SurpriseItemMap.swift`

### 🚗 Road trip

| 物品 | Note |
|------|------|
| Car phone mount | Hands-free navigation is the law in most places — and your co-pilot won't always be awake |
| Window sunshade | Parked in the sun, your steering wheel becomes untouchable — costs almost nothing to prevent |
| Flat shoes | Driving in heels reduces pedal feel and reaction time — a pair of flats to swap into before getting behind the wheel makes a real difference on long stretches |
| Car air freshener | A long drive in a stale car is draining — a subtle scent changes the whole atmosphere |
| Car travel blanket | Passenger-seat naps are so much better with a real blanket — one that lives in the boot ready to go |
| Disposable camera | Your phone will capture everything perfectly. Which is exactly why a disposable feels different — the grain, the not-knowing, the waiting |

### ✈️ Long-haul flight

| 物品 | Note |
|------|------|
| Steam eye mask | Ten minutes of warm darkness mid-flight feels like a reset — most people who try one become converts |
| Blister patches | Fast airport transfers and long terminal walks can shred your heels — applying one early can save your first day |
| Mint gum | Chewing one before landing helps with dry cabin mouth and makes you feel fresher on arrival |
| Hand cream | Cabin air is brutally dry — hands suffer first, and most people only notice once they're already cracked |
| Disposable slippers | Shoes off, slippers on — a small ritual that makes a long flight feel far more civilised |
| Flight snacks | Airline food timing rarely matches when you're actually hungry — keep something in your bag for the gap |
| Book | A physical book for long-haul — no battery anxiety, no glare, and you will actually finish it away from notifications |
| Essential oil roller | A small roller of lavender or peppermint does two things: eases tension headaches mid-flight, and marks the moment you apply it at the gate as the real start of the trip |

### 💍 Honeymoon

| 物品 | Note |
|------|------|
| Scented candle | A small candle transforms a hotel room — that smell will mean 'the honeymoon' for years afterwards |
| Massage oil | For evenings with nowhere to be — the right scent shifts the whole mood of a room in a way that nothing else quite does |
| Bath salts | One evening, run a bath — it is a small decision that can make a whole trip feel like it was properly lived |
| Silk sleep mask | Softer and cooler than a regular eye mask — a small upgrade that makes the nights feel like they belong to the trip |
| Instax / instant camera | A photo you hold in your hands sixty seconds after taking it is a different kind of memory |
| Journey journal | Somewhere to write down the small details before they blur together into just 'the honeymoon' |

### 🎒 Backpacking

| 物品 | Note |
|------|------|
| Ziplock bags | Waterproofing documents, organising small items, separating wet clothes — endlessly useful |
| Mini clips | Tiny but surprisingly versatile: clip wet socks to dry, seal snack bags, or secure loose small items |
| Headlamp + batteries | Essential for hostel dorm access in the dark without waking eight strangers |
| Instant coffee | For early mornings before the café opens — one sachet weighs nothing and can save a slow start anywhere in the world |
| Tea bags | A few teabags weigh almost nothing and turn any hostel kettle into a proper ritual — one of the smallest luxuries worth packing |

### 🏨 City break

| 物品 | Note |
|------|------|
| Comfort insoles | City days can hit 20k+ steps — insoles can save your feet by day two |
| Collapsible tote bag | You will buy something at a market or deli — saves scrambling for a bag at the checkout |
| Collapsible insulated bag | For market hauls, picnic supplies, or keeping café pastries intact — packs flat when not in use |
| Stain remover pen | When coffee or sauce lands on light clothes, a quick swipe can save you from a whole day of awkward stains |
| Pocket tissues | Public restrooms and small shops do not always have tissues — this tiny backup saves the moment more often than you think |

### ☀️ Tropical / beach

| 物品 | Note |
|------|------|
| Snorkel mask | A full-face snorkel mask changes the experience entirely — clear vision, easy breathing, no learning curve |
| Reef-safe sunscreen | Regular sunscreen damages coral reefs — worth switching in tropical waters |
| After-sun gel | Skin that's had a good day in the sun deserves this in the evening — the difference between waking up glowing and waking up sore |
| Waterproof phone pouch | Clip it on and take your phone into the water — suddenly every boat trip, beach swim, or waterfall is fully documented |

### ❄️ Winter / cold

| 物品 | Note |
|------|------|
| Portable electric kettle | Hot water on demand in your hotel room — instant noodles at midnight, morning tea without waiting for room service |
| Rechargeable hand warmer | Warm hands change everything in the cold — and unlike disposable ones, this one charges your phone in a pinch too |
| Hot chocolate sachets | A cup of hot chocolate in a cold room after a day in the snow is one of those small things that makes a trip feel complete |

### 🥾 Hiking / camping

| 物品 | Note |
|------|------|
| Energy gel / dark chocolate | Real hunger hits on a long ascent — something dense and rewarding at the summit makes the whole climb feel worth it |
| Foldable hiking stool | Somewhere to sit at the viewpoint — standing and looking is fine, sitting and looking is something else |
| Duct tape (small roll) | Fixes a broken boot sole, a torn strap, or a blister spot — worth the 30g |

### 🚢 Cruise

| 物品 | Note |
|------|------|
| Magnetic hooks | Cruise cabin walls are magnetic, and most people don't know until they've already unpacked — a few hooks can completely change how the room works |
| Formal accessories | A tie clip or silk scarf — the details that make a formal dinner outfit feel considered rather than thrown together |
| Portable fan | Cabins can get warm, especially in tropical ports — a small USB fan is a real sleep improvement |
| Acupressure wristbands | Worn on the pressure point above the wrist — more stylish than patches and surprisingly effective for mild seasickness |

### 💼 Business

| 物品 | Note |
|------|------|
| Wrinkle-release spray | Meeting clothes out of a suitcase always need a refresh — no iron required |
| Travel steamer | De-creases a shirt in two minutes — more effective than an iron on most fabrics, and takes up almost no space |
| Shoe care kit | Scuffed shoes undermine an otherwise sharp outfit — a quick buff before a client meeting takes thirty seconds |
| Foldable hangers | Hotel rooms never have enough — three extra hangers solve the whole wardrobe problem |

### 👶 Travelling with kids

| 物品 | Note |
|------|------|
| Magnetic drawing board | Mess-free drawing that resets instantly — endlessly reusable on long journeys |
| Kids headphones | Volume-limited and properly sized — lets them watch their shows without disturbing everyone around them |
| Night light | New rooms are dark in unfamiliar ways — a simple plug-in night light prevents middle-of-the-night panic |
| Familiar snacks from home | Picky eaters + unfamiliar food = avoidable stress — come prepared |
| Sticker book or activity pad | For the unavoidable waiting — restaurants, airports, long car journeys |

### ⛰ High altitude

| 物品 | Note |
|------|------|
| Portable oxygen can | Compact enough to slip in a day bag — a quick few breaths at altitude does genuinely help, and the peace of mind is worth it |

### 🌧 Rainy city

| 物品 | Note |
|------|------|
| Disposable rain poncho | Packs to the size of a biscuit, costs almost nothing — for when the umbrella is in the bag and the rain starts now |
| Waterproof shoe covers | Pull on over any shoes in seconds — keeps feet dry without having to plan your footwear around the forecast |
| Waterproof zip pouch | In heavy rain, putting your phone, cards, and tickets inside removes a lot of avoidable stress |

### 🌸 On / near period

| 物品 | Note |
|------|------|
| Dark-coloured bottoms | One pair of dark trousers or a dark skirt — a quiet confidence on heavier days |
| Portable hot water bottle | Fill from the hotel kettle — a hot water bottle on cramps is still the most effective thing, wherever you are |
| Brown sugar ginger tea | A hot cup of this does things for cramp and mood that no tablet quite matches — harder to find abroad than you'd think |
| Disposable toilet seat covers | During long days out, these make unfamiliar public restrooms feel much more comfortable |

### 💊 Daily medication

| 物品 | Note |
|------|------|
| Pill organiser | Easier and lighter than carrying full bottles — one for each day |

### 💻 Remote work

| 物品 | Note |
|------|------|
| Blue light glasses | Eight hours at a screen in a new place. A small defence against the slow headache that builds through the afternoon |
| Pocket notebook | For thinking that doesn't belong in a doc. Keep it on the desk, not buried in the bag |
| Portable desk pad | Any surface becomes a workspace with a desk pad under your hands — a simple trick that makes rented rooms feel like yours |

---

## 备注

- SceneItemMap 里部分物品未收录在 ItemCatalog（如 Snacks、Nuts、Car insurance docs、Foldable chair、Picnic mat、Backpack rain cover、Microfibre towel、Quick-dry clothing、Padlock、Sun hat、Rash guard、Swimming goggles、Waterproof bag、Waterproof jacket、Waterproof shoes、Waterproof phone case、Altitude sickness pills、Warm base layer、Windproof jacket、Thermal socks、Compression socks、Business cards、Formal shirt / blouse、Formal dinner outfit、Dress shoes、Wrinkle-release spray、Trail snacks / energy bars、Trekking poles、Change of clothes (extra)、Snacks for kids），这些物品只能通过场景推荐进入清单，用户无法在分类挑选里手动找到。
- SurpriseItemMap 里的物品同样大多数不在 ItemCatalog 中，属于独立数据。
