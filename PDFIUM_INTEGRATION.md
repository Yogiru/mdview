# Интеграция pdfium.dll — переносимое руководство

Описание того, как в MdView подключён просмотр PDF через **опциональную** `pdfium.dll`,
чтобы повторить это в другом проекте (Pascal/Lazarus или любой Win32-GUI-программе)
с минимальными затратами. Архитектура универсальна — меняется только синтаксис.

## Идея

- `mdview.exe` **не линкуется** с pdfium статически. Библиотека грузится динамически
  (`LoadLibrary` + `GetProcAddress`) при первой попытке открыть `.pdf`.
- Нет dll → приложение полностью работоспособно, `.pdf` даёт вежливый диалог.
- Страницы рендерятся pdfium'ом в BGRA-битмап → кодируются в **PNG** → отдаются
  HTML-движку (Pixie) как `<img src="pdf-page://N">` через обработчик кастомной схемы.
- Таким образом весь PDF — это один HTML-документ из вертикальных `<div id="pN">`.
  Скролл, зум, outline-якоря — бесплатно, их уже умеет вьювер.

## Где взять pdfium.dll

- Готовые сборки: `github.com/bblanchon/pdfium-binaries` → `pdfium-win-x86.tgz`
  (или `win-x64` под вашу битность — **битность dll обязана совпадать с процессом!**).
- Не брать самый свежий релиз наугад — раз в релиз-цикл выходят мажорные сборки;
  в проекте использована сборка chromium/7734, ~6.6 МБ, лицензия **BSD-3** (совместима с MIT/GPL).
- Кладётся рядом с exe.

## Три подводных камня (проверено на практике)

### 1. Calling convention — cdecl, а не stdcall

В сборках bblanchon `FPDF_CALLCONV` **пустой** → экспорты `cdecl`.
Заголовок `fpdfview.h` даёт `stdcall` только если определён `FPDFSDK_EXPORTS`.
Если объявить импорты `stdcall` — dll выполнит `ret` на лишние байты,
стек развалится → **SIGSEGV при первом же вызове**. Все сигнатуры — `cdecl`.

### 2. FPU exception mask

Pdfium (v8/skia внутри) рассчитан на **замаскированные** FP-исключения.
FPC по умолчанию их включает → `EInvalidOp` прямо внутри `FPDF_LoadPage`.
Перед каждой серией вызовов в dll ставь маску (дешёвый `fldcw`):

```pascal
SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                 exOverflow, exUnderflow, exPrecision]);
```

В C/C++ аналог — `_control87(MCW_EM, MCW_EM)` / `fesetenv`. Ставить её стоит
перед каждым блоком вызовов pdfium — host-код мог маску перезаписать.

### 3. `lazbuild` без `-B` (incremental)

При добавлении нового юнита в проект инкрементальная сборка может не
перелинковать старый объектник — в exe останется старая версия кода
(поймал так SIGSEGV: исходник `cdecl`, объектник `stdcall`).
При сомнениях — `lazbuild -B`.

## Схема вызовов pdfium

Используются 15 экспортов (все `cdecl`), хватит 13 обязательных:

| Экспорт | Сигнатура (C) | Назначение |
|---|---|---|
| `FPDF_InitLibrary` | `void()` | init, один раз |
| `FPDF_DestroyLibrary` | `void()` | finit, при выходе |
| `FPDF_LoadDocument` | `doc*(utf8 path, password)` | открыть; nil → `FPDF_GetLastError` |
| `FPDF_CloseDocument` | `void(doc)` | |
| `FPDF_GetPageCount` | `int(doc)` | |
| `FPDF_LoadPage` | `page*(doc, index)` | |
| `FPDF_ClosePage` | `void(page)` | |
| `FPDF_GetPageSizeByIndexF` | `bool(doc, idx, FS_SIZEF*)` | размеры в пунктах (1/72") |
| `FPDFBitmap_CreateEx` | `bmp*(w,h,fmt,buf,stride)` | fmt=4 → BGRA |
| `FPDFBitmap_FillRect` | `bool(bmp,l,t,w,h,argb)` | белый фон `$FFFFFFFF` |
| `FPDFBitmap_GetBuffer` | `void*(bmp)` | указатель на пиксели |
| `FPDFBitmap_GetStride` | `int(bmp)` | байт на строку |
| `FPDFBitmap_Destroy` | `void(bmp)` | |
| `FPDF_RenderPageBitmap` | `void(bmp,page,sx,sy,w,h,rot,flags)` | flags=`FPDF_ANNOT\|FPDF_LCD_TEXT` ($03) |
| `FPDF_GetMetaText` | `u32(doc,"Title",buf,len)` | опционально — заголовок; буфер UTF-16LE |
| `FPDF_GetLastError` | `u32()` | коды: 3=битый файл, 4=пароль |

### Порядок рендера страницы

```
SetExceptionMask(...)                       // см. камень №2
FPDF_GetPageSizeByIndexF(doc, i, &size)     // size.width/height в пунктах
w = round(size.width  * scale);  h = round(size.height * scale)
FPDF_LoadPage(doc, i)
bmp = FPDFBitmap_CreateEx(w, h, 4 /*BGRA*/, NULL, 0)
FPDFBitmap_FillRect(bmp, 0,0, w,h, 0xFFFFFFFF)   // обязательно белый — иначе мусор
FPDF_RenderPageBitmap(bmp, page, 0,0, w,h, 0, FPDF_ANNOT|FPDF_LCD_TEXT)
buf = FPDFBitmap_GetBuffer(bmp); stride = FPDFBitmap_GetStride(bmp)
   → buf это BGRA-строки по stride байт; alpha игнорируем → RGB
FPDFBitmap_Destroy(bmp);  FPDF_ClosePage(page)
```

Замечания:

- `FPDF_LoadDocument` ждёт путь в **UTF-8** (WideChar → UTF8Encode → PAnsiChar).
- Пустая страница/белый фон: без `FillRect` буфер — мусор.
- `FPDF_RenderPageBitmap` без `FPDF_ANNOT` не рисует аннотации/ссылки;
  `FPDF_LCD_TEXT` — сглаживание текста по субпикселям (лучше выглядит).
- Защита от «плакатных» страниц: пока `w|h > 4096` — `scale /= 2`
  (иначе одна страница съест гигабайты).

## PNG-кодирование страницы (без внешних библиотек)

fcl-image (`TFPMemoryImage`+`TFPWriterPNG`) медленный — ~400 мс/стр.
Свой энкодер на `zstream`+`crc` (оба юнита в стандартной поставке FPC) — ~95 мс/стр:

1. Сигнатура `\x89PNG\r\n\x1a\n`.
2. `IHDR` (13 байт): width,height(BE32), bitdepth=8, colortype=2 (RGB).
3. `IDAT`: zlib-поток (`TCompressionStream(clfastest)`); для каждой строки —
   байт фильтра `0` + W*3 байта RGB (BGRA→RGB: берём первые 3 байта пикселя).
4. `IEND`. CRC каждого чанка — `crc32()` из юнита `crc`.

Зачем PNG, а не BMP: страница ~0.2–0.5 МБ против ~6 МБ — для 400 страниц
это разница между «норм» и OOM на 32-битном адресном пространстве.

## Склейка с вьювером (Pixie-подобным HTML-движком)

1. `TPdfDoc` (см. `PdfDoc.pas`) — чёрный ящик: `Open/Close/PageCount/
   PageSizePt/RenderPagePng/DocTitle`. Наружу — только PNG-стримы.
2. `BuildPdfHtml` генерирует:

```html
<div class="pdfpage" id="p0">
  <img src="pdf-page://0" style="width:<size.width>px">
  <div class="pdfpgnum">1 / 57</div>
</div>
```

   `style="width:Npx"` выставляется из `PageSizePt` — тогда CSS-зум Pixie
   масштабирует «как положено» (px = pt × 96/72 логически).

3. Обработчик кастомной схемы (у Pixie — `OnFetchUrl(Url, Stream, Success)`):
   распарсил `pdf-page://N` → `PdfPageStream(N)` → скопировал в `Stream`,
   `Success := True`. Там же кэш: `TList` из `TMemoryStream` по индексу —
   повторный показ страницы бесплатен.

4. Outline: плоский список «Страница N» с `Id := 'pN'` — клик по нему
   вызывает уже существующий `JumpToAnchor('pN')` (якорь на `<div id="pN">`).
   Настоящие закладки PDF (bookmark tree) не реализованы.

5. Лимиты: `PdfMaxPages = 400` (защита i386-памяти; в конец документа
   дописывается «показаны первые N из M»). `PdfRenderScale = 2.0` —
   рендер с 2× запасом, чтобы зум Pixie не мылил.

## Чеклист портирования

- [ ] Скачать `pdfium.dll` нужной битности (x86 для 32-битного процесса!).
- [ ] Ленивая загрузка: `LoadLibraryW(путь_рядом_с_exe)` → fallback `LoadLibraryW('pdfium.dll')`.
- [ ] 13 обязательных `GetProcAddress`; `FPDF_GetMetaText`/`FPDF_GetLastError` — опциональные.
- [ ] Все сигнатуры — **`cdecl`**.
- [ ] `SetExceptionMask` перед каждым блоком вызовов в dll.
- [ ] Путь к файлу — UTF-8.
- [ ] Рендер: CreateEx(BGRA) → FillRect(белый) → RenderPageBitmap(ANNOT|LCD_TEXT) → GetBuffer/Stride → PNG → Destroy/ClosePage.
- [ ] PNG-энкодер на zlib (или штатная image-библиотека, если не критична скорость).
- [ ] HTML: `<div id="pN"><img src="pdf-page://N">` + кастомная схема + кэш потоков.
- [ ] Лимиты: макс. страниц, макс. пикселей стороны (4096), сообщение об усечении.
- [ ] Без dll — мягкая деградация (дружественный диалог, а не crash).
- [ ] Тест-кейсы: нет dll / битый pdf / защищённый паролем / 400+ страниц / pdf с кириллическим путём.

## Файлы-референсы в этом проекте

- `PdfDoc.pas` — вся логика pdfium + PNG-энкодер (~490 строк, самодостаточен:
  зависимости только `Classes, SysUtils, Math, zstream, crc, Windows`).
- `MainForm.pas` — интеграция: `LoadPdf/ClosePdf/BuildPdfHtml/PdfPageStream`,
  ветка `dkPdf` в `OnFetchUrl`, outline, reload, фильтр диалога открытия.
- `fpdfview.h` (можно взять из bblanchon-архива) — эталон сигнатур.
