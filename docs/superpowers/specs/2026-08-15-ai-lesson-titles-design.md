# KI-generierte Stundentitel

## Ziel

Aufgezeichnete Stunden werden in jeder iOS-Liste primär mit einem kurzen,
inhaltlich passenden KI-Titel dargestellt. Das Fach bleibt als klar erkennbare
sekundäre Information erhalten.

## Bestehender Datenfluss

Das Backend erzeugt nach dem Ende einer ausreichend langen Aufnahme automatisch
eine Zusammenfassung. Deren erste Zeile ist ein drei- bis sechswörtiges Thema,
das die Stundenliste bereits als optionales Feld `topic` erhält. Das iOS-Modell
`BackendAPI.LessonInfo` decodiert `topic` schon heute. Die Fachansicht verwendet
es bereits, andere Listen greifen jedoch noch direkt auf Stundenplan-Titel,
Fach oder Datum zurück.

Dieses Feature erzeugt keinen zweiten Titel und führt kein neues API-Feld ein.
Es macht den vorhandenen KI-Titel in der gesamten iOS-App konsistent sichtbar.

## Zentrale Darstellungsregel

`BackendAPI.LessonInfo` erhält eine gemeinsame Präsentationslogik für
aufgezeichnete Stunden:

1. Ein nicht leerer `topic`-Wert ist immer der primäre Titel.
2. Bei älteren Zusammenfassungen ohne separates `topic` wird, soweit möglich,
   der bereits vorhandene Titel-Fallback aus `summaryExcerpt` verwendet.
3. Fehlt beides, folgen Stundenplan-Titel beziehungsweise Fach.
4. Als letzter Fallback wird ein lokalisiertes Datum angezeigt.

Das Fach wird separat bestimmt und nie als KI-Titel ausgegeben, wenn ein
echtes Thema vorhanden ist. Leere oder nur aus Leerzeichen bestehende Werte
werden ignoriert.

## Darstellung

Jede Zeile oder Auswahl, die eine aufgezeichnete Stunde repräsentiert, zeigt:

- den KI-Titel als erste, visuell stärkste Zeile;
- das Fach als sekundäre Kennzeichnung;
- Datum, Uhrzeit oder Dauer dort, wo die jeweilige Ansicht diese Metadaten
  bereits benötigt.

Betroffen sind insbesondere:

- die Aufnahmen innerhalb eines Fachordners;
- die Stundenauswahl im Chat;
- die Stundenauswahl im Lernen-Bereich;
- Quellenangaben zu Lernkarten, soweit die Listenantwort den Titel bereitstellt;
- weitere wiederverwendete Zeilen, die `BackendAPI.LessonInfo` anzeigen.

Die Fachordner selbst bleiben nach Fächern benannt. Sie repräsentieren ein Fach
und keine einzelne Aufnahme.

## Zustände und Kompatibilität

- Während eine Stunde noch keine Zusammenfassung besitzt, bleibt sie über den
  Fallback eindeutig auswählbar.
- Alte Server ohne `topic` bleiben kompatibel, weil das Feld optional ist.
- Alte Stunden können aus dem Zusammenfassungsausschnitt einen Titel ableiten;
  andernfalls bleiben Fach/Stundenplan-Titel und Datum erhalten.
- Sehr kurze Aufnahmen, für die das Backend bewusst keine Zusammenfassung
  erzeugt, zeigen keinen erfundenen KI-Titel.
- Offline zwischengespeicherte `LessonInfo`-Objekte verwenden dieselbe
  Darstellungsregel wie frisch geladene Daten.

## Suche und Barrierefreiheit

Die Stundensuche berücksichtigt neben Fach, Lehrkraft und Raum auch `topic` und
`summaryExcerpt`, damit ein sichtbarer KI-Titel auffindbar ist. Kombinierte
Zeilen bleiben für VoiceOver als eine verständliche Einheit lesbar; der Titel
wird vor dem Fach angesagt.

## Tests

Unit-Tests prüfen die Priorität und alle Fallbacks der zentralen
Darstellungsregel sowie die Suche nach KI-Titeln. Bestehende UI-Testdaten werden
so verwendet oder erweitert, dass die wichtigsten Stundenlisten einen KI-Titel
als Hauptzeile und das Fach als sekundäre Information zeigen. Abschließend
werden Swift-Tests, Formatierung/Lint und ein iOS-Simulator-Build ausgeführt.

## Nicht Bestandteil

- Manuelles Umbenennen von KI-Titeln;
- eine zusätzliche KI-Anfrage nur für den Titel;
- eine Backend- oder Datenbankmigration;
- KI-Titel für Stundenplan-Einträge, die nicht aufgezeichnet wurden.
