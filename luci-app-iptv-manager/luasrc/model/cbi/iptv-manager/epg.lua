local m, s, o

m = Map("iptv", translate("Настройки телепрограммы (EPG)"),
    translate("Загрузка и управление EPG. EPG хранится в RAM (/tmp) и не занимает флеш-память."))

m:chain("iptv")

o = m:option(Value, "epg_url", translate("URL EPG (XMLTV)"))
o.placeholder = "http://epg.cdntv.online/lite.xml.gz"
o.datatype = "string"
o.description = "Поддерживаются XML и XML.gz. Рекомендуемый: http://epg.cdntv.online/lite.xml.gz"

return m
