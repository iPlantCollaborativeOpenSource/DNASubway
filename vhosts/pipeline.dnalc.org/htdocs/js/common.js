function gl_hide_definition() {
	$$('span.con_GlossaryTextbox').each(function(sp) {
		if (sp.style.display == 'block') {
			//console.info("**: " + sp.style.display + "|" + sp.innerHTML);
			sp.style.display = 'none';
		}
	});
}

function gl_show_definition(el) {
	gl_hide_definition();
	//alert($(el).ancestors()[1].next().innerHTML);
	//alert(el.parentNode.parentNode.next());
	$(el).ancestors()[1].next().style.display = 'block';
}

//------------------------
function show_messages(html, isError) {
	if (!html || !UI) {
		//alert(html);
		return;
	}
	var resizable = true;
	var options = {	
			resizable: false,
        	width: 400,
	        height: 200,
	        shadow: true,
	        draggable: false
		};
	if (navigator.userAgent.indexOf('MSIE') != -1) {
		// IE doen't like this option!!!
		delete options['resizable'];
	}
	var _w = new UI.Window(options).center();
	html = "<div class=\"conNewPro_title\" style=\"vertical-align: middle; padding: 20px\">" + html + "</div>";
	if (isError) {
		_w.setHeader("Error");
	}	
	_w.setContent(html);
	_w.show(true);
	_w.activate();
	return _w;
}

function show_errors(html) {

	if (!html || !UI) {
		return;
	}
	show_messages(html, 1);
}
//------------------------

function check_description_length(e) {

	var node = (e.target) ? e.target : ((e.srcElement) ? e.srcElement : null);
	$('desc_len').innerHTML = node.value.length;
	if (node.value.length >= 141) {
		show_messages('Maximum 140 chars for the description.');
		node.value = node.value.substr(0, 140);
		$('desc_len').innerHTML = node.value.length;
		node.blur();
	}
}
//------------------------
Event.observe(window, 'load', function() {
	// check for errors
	var err = $("error_list");
	if (err) {
		var html = err.innerHTML;
		if (html) {
			show_errors(html);
		}
	}
	
	// check messages
	var mess = $("message_list");
	if (mess) {
		var html = mess.innerHTML;
		if (html) {
			show_messages(html);
		}
	}
});