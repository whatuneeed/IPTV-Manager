local m, s, o

m = Map("iptv", translate("Настройки плейлиста"),
    translate("Загрузка и управление IPTV плейлистом"))

m:chain("iptv")

-- Playlist name
o = m:option(Value, "playlist_name", translate("Название плейлиста"))
o.placeholder = "Мой плейлист"
o.rmempty = true

-- Playlist type
o = m:option(ListValue, "playlist_type", translate("Тип плейлиста"))
o:value("url", "По ссылке (URL)")
o:value("file", "Из файла")
o:value("provider", "Провайдер")
o:value("", "Не загружен")

-- Playlist URL
o = m:option(Value, "playlist_url", translate("URL плейлиста"))
o.placeholder = "https://example.com/playlist.m3u"
o:depends("playlist_type", "url")
o.datatype = "string"

-- Playlist source file
o = m:option(Value, "playlist_source", translate("Путь к файлу"))
o.placeholder = "/tmp/playlist.m3u"
o:depends("playlist_type", "file")

-- Provider config
o = m:option(Value, "provider_name", translate("Название провайдера"))
o:depends("playlist_type", "provider")

o = m:option(Value, "provider_login", translate("Логин провайдера"))
o:depends("playlist_type", "provider")

o = m:option(Value, "provider_pass", translate("Пароль провайдера"))
o.password = true
o:depends("playlist_type", "provider")

o = m:option(Value, "provider_server", translate("Сервер провайдера"))
o.placeholder = "http://example.com"
o:depends("playlist_type", "provider")

return m
