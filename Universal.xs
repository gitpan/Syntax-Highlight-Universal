#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#ifndef call_sv
	#define call_sv perl_call_sv
#endif

#include "CachingHRCParser.h"

#include <stdio.h>
#include <string.h>

#include <xml/xmldom.h>
#include <common/io/InputSource.h>
#include <colorer/parsers/HRCParserImpl.h>
#include <colorer/parsers/TextParserImpl.h>

enum
{
	cbAddRegion,
	cbEnterScheme,
	cbLeaveScheme,
	cbEnd
};
const char* callbackNames[] = {
	"addRegion",
	"enterScheme",
	"leaveScheme"
};
SV* callback[cbEnd];

AV* linesList = NULL;

class PrivateLineSource : public LineSource
{
public:
	String* getLine(int lineNo)
	{
		if (av_len(linesList) < lineNo)
			return null;

		return new DString(SvPV(*av_fetch(linesList, lineNo, 0), PL_na));
	}

	int getLineCount()
	{
		return av_len(linesList) + 1;
	}
};

class PrivateRegionHandler : public RegionHandler
{
public:
	virtual void addRegion(int lineNum, String* line, int sx, int ex, const Region* region)
	{
		if (!callback[cbAddRegion])
			return;

		dSP;

		ENTER;
		SAVETMPS;

		PUSHMARK(SP);
		XPUSHs(sv_2mortal(newRV_inc((SV*)linesList)));
		XPUSHs(sv_2mortal(newSViv(lineNum)));
		XPUSHs(sv_2mortal(newSViv(sx)));
		XPUSHs(sv_2mortal(newSViv(ex)));
		XPUSHs(getRegionsList(region));
		PUTBACK;
		call_sv(callback[cbAddRegion], G_DISCARD);

		FREETMPS;
		LEAVE;
	}

	virtual void enterScheme(int lineNum, String* line, int sx, int ex, const Region* region, const Scheme* scheme)
	{
		if (!callback[cbEnterScheme])
			return;

		dSP;

		ENTER;
		SAVETMPS;

		PUSHMARK(SP);
		XPUSHs(sv_2mortal(newRV_inc((SV*)linesList)));
		XPUSHs(sv_2mortal(newSViv(lineNum)));
		XPUSHs(sv_2mortal(newSViv(sx)));
		XPUSHs(sv_2mortal(newSViv(ex)));
		XPUSHs(sv_2mortal(newSVpv((char*)scheme->getName()->getChars(), 0)));
		XPUSHs(getRegionsList(region));
		PUTBACK;
		call_sv(callback[cbEnterScheme], G_DISCARD);

		FREETMPS;
		LEAVE;
	}

	virtual void leaveScheme(int lineNum, String* line, int sx, int ex, const Region* region, const Scheme* scheme)
	{
		if (!callback[cbLeaveScheme])
			return;

		dSP;

		ENTER;
		SAVETMPS;

		PUSHMARK(SP);
		XPUSHs(sv_2mortal(newRV_inc((SV*)linesList)));
		XPUSHs(sv_2mortal(newSViv(lineNum)));
		XPUSHs(sv_2mortal(newSViv(sx)));
		XPUSHs(sv_2mortal(newSViv(ex)));
		XPUSHs(sv_2mortal(newSVpv((char*)scheme->getName()->getChars(), 0)));
		XPUSHs(getRegionsList(region));
		PUTBACK;
		call_sv(callback[cbLeaveScheme], G_DISCARD);

		FREETMPS;
		LEAVE;
	}
private:
	SV* getRegionsList(const Region* region)
	{
		AV* regions = newAV();
		while (region)
		{
			av_push(regions, sv_2mortal(newSVpv((char*)region->getName()->getChars(), 0)));
			region = region->getParent();
		}
		return sv_2mortal(newRV_inc((SV*)regions));
	}
};

PrivateLineSource lines;
PrivateRegionHandler regionHandler;
CachingHRCParser hrcParser;
TextParserImpl parser;

MODULE = Syntax::Highlight::Universal	PACKAGE = Syntax::Highlight::Universal

PROTOTYPES: ENABLE

BOOT:
	parser.setLineSource(&lines);
	parser.setRegionHandler(&regionHandler);

void
_addConfig(file)
	char* file;
CODE:
	InputSource* typesIS = InputSource::newInstance(&DString(file));
	hrcParser.loadSource(typesIS);

const char*
_highlight(type, _linesList, _callbacks)
	char* type;
	SV* _linesList;
	SV* _callbacks;
CODE:
	if (SvROK(_linesList) && SvTYPE(SvRV(_linesList)) == SVt_PVAV)
		linesList = (AV*)SvRV(_linesList);
	else
		croak("linesList is not an array reference");

	HV* callbacks;
	if (SvROK(_callbacks) && SvTYPE(SvRV(_callbacks)) == SVt_PVHV)
		callbacks = (HV*)SvRV(_callbacks);
	else
		croak("callbacks is not a hash reference");

	for (int i = 0; i < cbEnd; i++)
	{
		SV** value = hv_fetch(callbacks, (char*)callbackNames[i], strlen(callbackNames[i]), FALSE);
		callback[i] = (value ? *value : NULL);
	}

	try
	{
		String* typeStr = new DString(type);
		FileType* fileType = hrcParser.getFileType(typeStr);
		delete typeStr;
		if (fileType == null)
			croak("Unknown type: %s", type);

		parser.setFileType(fileType);
		parser.parse(0, lines.getLineCount());
	}
	catch(Exception& e)
	{
		croak(e.getMessage()->getChars());
	}
	catch(...)
	{
		croak("Unknown error");
	}

void
_serialize(file)
	char* file;
CODE:
	hrcParser.serializeToFile(file);

void
_deserialize(file)
	char* file;
CODE:
	hrcParser.deserializeFromFile(file);
