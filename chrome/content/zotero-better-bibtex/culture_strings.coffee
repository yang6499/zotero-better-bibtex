Zotero.BetterBibTeX._CultureStrings = Zotero.BetterBibTeX.CultureStrings
Zotero.BetterBibTeX.CultureStrings = {}

for lang, strings of Zotero.BetterBibTeX._CultureStrings
  next if lang == 'lang'

  obj = {}

  weekdays = (strings[d] for d in [ 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'])
  obj.weekdays = new RegExp("\\b(#{weekdays.join('|')})\\b")

  for month, i in months = [ 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December' ]
    month = (strings[m] for m in [month, month.slice(0, 3) + '_Abbr'])
    obj[if i < 8 then "0#{i+1}" else "#{i+1}"] = new RegExp("\\b(#{month.join('|')})\\b")

  Zotero.BetterBibTeX.CultureStrings[lang.toLowerCase()] = obj
  Zotero.BetterBibTeX.CultureStrings[lang.toLowerCase().replace(/-.*/, '')] = obj
  Zotero.BetterBibTeX.CultureStrings[strings.englishName.replace(/\s+\(.*/, '')] = obj
  Zotero.BetterBibTeX.CultureStrings[strings.nativeName.replace(/\s+\(.*/, '')] = obj

delete Zotero.BetterBibTeX._CultureStrings
