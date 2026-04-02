'use strict';
'require view';
'require form';
'require uci';

return view.extend({
    load: function() {
        return Promise.all([uci.load('iptv')]);
    },

    render: function() {
        var m, s, o;

        m = new form.Map('iptv', _('Телепрограмма (EPG)'),
            _('Загрузка и управление EPG. EPG хранится в RAM (/tmp) и не занимает флеш-память.'));

        s = m.section(form.TypedSection, 'main', null, true);
        s.anonymous = true;

        o = s.option(form.Value, 'epg_url', _('URL EPG (XMLTV)'));
        o.placeholder = 'http://epg.cdntv.online/lite.xml.gz';
        o.description = _('Поддерживаются XML и XML.gz. Рекомендуемый: http://epg.cdntv.online/lite.xml.gz');

        return m.render();
    }
});
