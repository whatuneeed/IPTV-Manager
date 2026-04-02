local m, s, o

m = Map("iptv", translate("Настройки безопасности"),
    translate("Пароль на админку и API токен для защиты IPTV Manager"))

m:chain("iptv")

o = m:option(Value, "admin_user", translate("Логин админки"))
o.placeholder = "Оставьте пустым для отключения"
o.rmempty = true

o = m:option(Value, "admin_pass", translate("Пароль админки"))
o.password = true
o.placeholder = "Оставьте пустым для отключения"
o.rmempty = true

o = m:option(Value, "api_token", translate("API токен"))
o.placeholder = "Оставьте пустым для отключения"
o.rmempty = true
o.description = "Передавайте в заголовке X-API-Token для доступа к API без пароля"

return m
