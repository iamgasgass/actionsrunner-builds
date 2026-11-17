# Bugfix audit (fork di Leviidev/Henge @ 7b55730)

Revisione del codice dell'app iOS (Swift), dell'host (C), dei dispositivi emulati e dello stack di restore.
Ogni voce: file, sintomo, causa, correzione.

## Crash nel passo "Write macOS" (installazione)

1. **ios/Henge/Installer.swift – jetsam (iOS chiude Henge) durante "Write macOS" su dispositivi da 6–8 GB** (#13, #59)
   La Mac temporanea del restore riceveva sempre fino a 4 GB. Il restore OS riempie tutta la RAM che ha con
   la cache dei ~15 GB che scrive, e quella memoria è fuori dal footprint di Henge: su un iPhone da 6 GB restavano
   ~1,5 GB a iOS e Henge → `vm-pageshortage` / `fc-thrashing`, app chiusa al 20–80 %.
   Ora il tetto dipende dalla RAM fisica: 2 GB sotto 7 GB, 3 GB sotto 10 GB, 4 GB oltre (`restoreRAMCapMB`).
2. **ios/Henge/InstallView.swift – trap Swift su `Int(fraction * 100)`**
   `Int(Double)` va in crash con NaN/infinito. La percentuale ora è sempre un numero finito in 0…1; anche la stima
   del tempo residuo è protetta.
3. **ios/Henge/Installer.swift – avanzamento letto dal C non validato**: clamp e scarto di NaN.
4. **ios/Henge/Installer.swift – dopo un restore fallito la VM restava accesa** (RAM, CPU e scritture su un disco
   poi cancellato). Ora viene fermata prima di rimuovere la Mac incompleta.

## Download

5. **ios/Henge/RangedDownload.swift – file .part più corto del file reale accettato come completo** (risposta 416):
   un IPSW troncato veniva installato. Ora il .part viene azzerato e il download riparte.
6. **ios/Henge/RangedDownload.swift – annullamento perso** se arrivava prima che il task esistesse.

## Crash nel motore / dispositivi

7. **devices/xhci.c – NULL dereference**: GET_REPORT del trackpad con id 0x3f impostava la lunghezza ma non il buffer
   sorgente → `memcpy(out, NULL, 16)` → crash di Henge pilotabile dal driver del guest. Corretto, più guardia generale
   (`src == NULL` → stall) e stringhe descrittore limitate alla dimensione del buffer.
8. **devices/virtio_blk.c – overflow di `sector * 512`**: un settore enorme tornava ad un offset dentro il disco.
   Ora è un errore I/O.
9. **core/memop.c – possibile NULL dereference** di `ram` nei target degli atomici.
10. **core/mmu.c – `pc_state` dereferenziato senza controllo** (il controllo era su `cpu->m`).

## Stack di restore (libusb shim)

11. **host/libusb_shim.c – use-after-free** nei callback hotplug: `fire()` chiamava le voci della lista dopo aver
    rilasciato il lock, mentre un deregister le liberava. Ora copia callback e user data.
12. **host/libusb_shim.c – lettura fuori buffer** nel parsing dei descrittori di configurazione (bLength non verificato
    contro la lunghezza), descrittori di configurazione < 9 byte, `calloc` non controllata.
13. **host/libusb_shim.c – `libusb_alloc_transfer` non controllata** nei trasferimenti sincroni (crash se NULL).
14. **host/libusb_shim.c – `libusb_get_string_descriptor_ascii`**: buffer non inizializzato e `length <= 0`
    scriveva fuori dal buffer del chiamante.

## Varie

15. **host/hvsparse.c – overflow `rec[0] + rec[1]`** nell'unpack di un disco importato (file malformato → scrittura
    fuori dimensione).
16. **ios/Henge/MacApps.swift – `String(cString:)` su campi `char[N]`** poteva leggere oltre il campo se non terminato.
17. **ios/Henge/SessionView.swift – blocco schermo lasciato disattivato** quando l'avvio della Mac falliva.

## Verifica

Non è possibile compilare l'app iOS fuori da macOS/Xcode: i file C modificati sono stati verificati con
`clang -fsyntax-only -Wall -Wextra` e con l'analizzatore statico di clang (`--analyze`), che non segnala più i
difetti sopra. Va fatta una build (Xcode o la tua GitHub Action) e un'installazione di prova su dispositivo.
