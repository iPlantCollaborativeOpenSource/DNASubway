
var being_dragged = false;
var element;

function mouser(event){
	var x;
	var y;
	if(being_dragged == true) {
		
		try{
			x=event.pageX;
			y=event.pageY;
		}
		catch(e) {
		
		};

		document.getElementById(element).style.left = x -5 +'px';
		document.getElementById(element).style.top = y -5 +'px';
	}
}

function mouse_down(event, ele_name) {
	being_dragged = true;
	element = ele_name;
	document.getElementById(element).style.cursor = 'move';
}

function mouse_up() {
	being_dragged = false;
	document.getElementById(element).style.cursor = 'auto';
} 

function zoomIn() {
	var r = scroll_a();
	
	var width = $('div_width').value;
	if (width == 12){
		$('sequence').addClassName('bases');
		$('div_width').value='13';
		$('zoom_in').disabled = true;
		$('sequence_but').disabled = true;
		$('zoom_in').addClassName('disabled');
		$('sequence_but').addClassName('disabled');
	}
	else if (width == 8){
		$('barcode').hide();
		$('sequence').show();
		$('sequence').removeClassName('bases');			
		$('div_width').value='12';			
	}
	else{
		$$('#barcode div div').each(function(el) {
			el.setStyle({
				width: 2*width + 'px'
			});
		});
		$('div_width').value=2*width;
	}
	$('alignment').scrollLeft = scroll_b(r);
	$('zoom_out').disabled = false;
	$('barcode_but').disabled = false;
	$('zoom_out').removeClassName('disabled');
	$('barcode_but').removeClassName('disabled');
}
function zoomOut() {
	var r = scroll_a();
	
	var width = $('div_width').value;
	if (width > 12){
		$('sequence').removeClassName('bases');
		$('div_width').value='12';
	}
	else if (width == 12){
		$('sequence').hide();
		$('barcode').show();
		$$('#barcode div div').each(function(el) {
			el.setStyle({
				width: '8px'
			});
		});			
		$('div_width').value='8';
	}
	else {
		$$('#barcode div div').each(function(el) {
			el.setStyle({
				width: width/2 + 'px'
			});
		});
		var new_width = width/2
		$('div_width').value= new_width;
		if (new_width == 1){
			$('zoom_out').disabled = true;
			$('barcode_but').disabled = true;
			$('zoom_out').addClassName('disabled');
			$('barcode_but').addClassName('disabled');
		}
	}
	$('alignment').scrollLeft = scroll_b(r);
	$('zoom_in').disabled = false;
	$('sequence_but').disabled = false;
	$('zoom_in').removeClassName('disabled');
	$('sequence_but').removeClassName('disabled');
}
function barcodeView() {
		$('sequence').hide();
		$('barcode').show();	
		$$('#barcode div div').each(function(el) {
			el.setStyle({
				width: '1px'
			});
		});
		$('div_width').value='1';
		$('zoom_in').disabled = false;
		$('sequence_but').disabled = false;
		$('zoom_in').removeClassName('disabled');
		$('sequence_but').removeClassName('disabled');
		$('zoom_out').disabled = true;
		$('barcode_but').disabled = true;
		$('zoom_out').addClassName('disabled');
		$('barcode_but').addClassName('disabled');
}
function seqView() {
		var r = scroll_a();
		$('barcode').hide();
		$('sequence').show();	
		$('sequence').addClassName('bases');
		$('alignment').scrollLeft = scroll_b(r);
		$('div_width').value='13';
		$('zoom_in').disabled = true;
		$('sequence_but').disabled = true;
		$('zoom_in').addClassName('disabled');
		$('sequence_but').addClassName('disabled');
		$('zoom_out').disabled = false;
		$('barcode_but').disabled = false;
		$('zoom_out').removeClassName('disabled');
		$('barcode_but').removeClassName('disabled');
}
function resizeFrame(f) {
	f.style.height = (f.contentWindow.document.body.scrollHeight + 20) + "px";
}
/*
* The purpose of scroll_a is to get 'r' - the ratio
* that will be used in scroll_b
*/
function scroll_a(){
	 // p is the current scroll position 
	 var p = $('alignment').cumulativeScrollOffset()[0]; 
	 
	 // x is the total scrollable area (total width of alignment div - width of visible alignment div)
	 var x = $('alignment').scrollWidth - $('alignment').getWidth();
	 
	 // r = p / x
	 var r = p/x;
	 
	 return r;
}

/*
* The purpose of scroll_b is to get the new 'p'
* (which will be used to set the new p)
*/
function scroll_b(r){
	// p = (r)(x)
	// we have r, get x below
	// x is the total scrollable area (total width of alignment div - width of visible alignment div)
	var x = $('alignment').scrollWidth - $('alignment').getWidth();
	
	var p = (r*x);
	
	return p;
}

document.observe("dom:loaded", function() {
	//$('div_width').value = $$('#barcode div div')[0].getStyle('width').split('px')[0];
	$('div_width').value = 1;
	$('zoom_out').disabled = true;
	$('barcode_but').disabled = true;
	$('zoom_out').addClassName('disabled');
	$('barcode_but').addClassName('disabled');
	$('zoom_in').disabled = false;
	$('sequence_but').disabled = false;
	try {document.body.addEventListener("mousemove", mouser, false);} catch (e) {};
	
});
