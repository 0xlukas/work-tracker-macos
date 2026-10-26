import Foundation

struct DailyQuote {
    let text: String
    let thinker: String
    let source: String?

    /// Deterministic quote of the day — same quote all day, different each day.
    static func quoteOfTheDay() -> DailyQuote {
        let daysSinceEpoch = Calendar.zurich.dateComponents([.day], from: Date(timeIntervalSince1970: 0), to: Date()).day ?? 0
        let index = abs(daysSinceEpoch) % all.count
        return all[index]
    }

    // swiftlint:disable function_body_length
    static let all: [DailyQuote] = [

        // ===============================================================
        // MARK: - Karl Marx — Economic and Philosophic Manuscripts (1844)
        // ===============================================================
        DailyQuote(
            text: "The worker becomes all the poorer the more wealth he produces, the more his production increases in power and range.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "The production of too many useful things results in too many useless people.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "The work is external to the worker — it is not part of his nature. He does not fulfil himself in his work but denies himself.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "The less you eat, drink, buy books, go to the theatre, think, love, theorise, sing, paint, fence — the more you save and the greater becomes your capital.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "Labour produces not only commodities; it produces itself and the worker as a commodity.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "The devaluation of the world of men is in direct proportion to the increasing value of the world of things.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "The worker puts his life into the object; but now his life no longer belongs to him but to the object.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "The alienation of the worker in his product means not only that his labour becomes an object, but that it exists outside him, independently, as something alien to him.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "The worker therefore only feels himself outside his work, and in his work feels outside himself.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "His labor is therefore not voluntary, but coerced; it is forced labor.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "As a result, man only feels himself freely active in his animal functions — eating, drinking, procreating — and in his human functions he no longer feels himself to be anything but an animal.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "Political economy regards the proletarian like a horse: he must receive enough to enable him to work.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),
        DailyQuote(
            text: "Labour produces for the rich wonderful things — but for the worker it produces privation. It produces palaces — but for the worker, hovels.",
            thinker: "Karl Marx",
            source: "Economic and Philosophic Manuscripts (1844)"
        ),

        // ===============================================================
        // MARK: - Karl Marx — Das Kapital
        // ===============================================================
        DailyQuote(
            text: "Capital is dead labor, which, vampire-like, lives only by sucking living labor, and lives the more, the more labor it sucks.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1 (1867)"
        ),
        DailyQuote(
            text: "Labor in a white skin cannot emancipate itself where it is branded in a black skin.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1 (1867)"
        ),
        DailyQuote(
            text: "Accumulation of wealth at one pole is at the same time accumulation of misery, agony of toil, slavery, ignorance, at the opposite pole.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1 (1867)"
        ),
        DailyQuote(
            text: "The directing motive, the end and aim of capitalist production, is to extract the greatest possible amount of surplus-value.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1 (1867)"
        ),
        DailyQuote(
            text: "Capitalist production is not merely the production of commodities, it is essentially the production of surplus-value.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1 (1867)"
        ),
        DailyQuote(
            text: "Labour-power is a commodity which its possessor, the wage-worker, sells to the capitalist.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1 (1867)"
        ),
        DailyQuote(
            text: "Labour is, in the first place, a process in which both man and Nature participate, and in which man of his own accord starts, regulates, and controls the material re-actions between himself and Nature.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 7 (1867)"
        ),
        DailyQuote(
            text: "By thus acting on the external world and changing it, he at the same time changes his own nature.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 7 (1867)"
        ),
        DailyQuote(
            text: "At the end of every labour-process, we get a result that already existed in the imagination of the labourer at its commencement.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 7 (1867)"
        ),
        DailyQuote(
            text: "Capital cares nothing for the length of life of labour-power. All that concerns it is simply and solely the maximum of labour-power that can be rendered fluent in a working-day.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 10 (1867)"
        ),
        DailyQuote(
            text: "Between equal rights force decides. Hence is it that in the history of capitalist production, the determination of what is a working-day presents itself as the result of a struggle between collective capital and collective labour.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 10 (1867)"
        ),
        DailyQuote(
            text: "When the labourer co-operates systematically with others, he strips off the fetters of his individuality, and develops the capabilities of his species.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 13 (1867)"
        ),
        DailyQuote(
            text: "The productive power developed by the labourer when working in co-operation is the productive power of capital.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 13 (1867)"
        ),
        DailyQuote(
            text: "Machinery is intended to cheapen commodities, and by shortening that portion of the working-day in which the labourer works for himself, to lengthen the other portion that he gives, without an equivalent, to the capitalist.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 15 (1867)"
        ),
        DailyQuote(
            text: "In its machinery system, modern industry has a productive organism that is purely objective, in which the labourer becomes a mere appendage to an already existing material condition of production.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 15 (1867)"
        ),
        DailyQuote(
            text: "That labourer alone is productive, who produces surplus-value for the capitalist, and thus works for the self-expansion of capital.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 16 (1867)"
        ),
        DailyQuote(
            text: "To be a productive labourer is, therefore, not a piece of luck, but a misfortune.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 1, Ch. 16 (1867)"
        ),
        DailyQuote(
            text: "The sole source of surplus-value is living labour.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 3 (1894)"
        ),
        DailyQuote(
            text: "In essence it always remains forced labour — no matter how much it may seem to result from free contractual agreement.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 3, Ch. 48 (1894)"
        ),
        DailyQuote(
            text: "Capital pumps the surplus-labour, which is represented by surplus-value and surplus-product, directly out of the labourers.",
            thinker: "Karl Marx",
            source: "Das Kapital, Vol. 3 (1894)"
        ),

        // ===============================================================
        // MARK: - Karl Marx — Theories of Surplus Value
        // ===============================================================
        DailyQuote(
            text: "Only that wage-labour is productive which produces capital.",
            thinker: "Karl Marx",
            source: "Theories of Surplus Value (1863)"
        ),
        DailyQuote(
            text: "Productive labour, in its meaning for capitalist production, is wage-labour which produces surplus-value for the capitalist.",
            thinker: "Karl Marx",
            source: "Theories of Surplus Value (1863)"
        ),

        // ===============================================================
        // MARK: - Karl Marx — The Civil War in France
        // ===============================================================
        DailyQuote(
            text: "With labour emancipated, every man becomes a working man, and productive labour ceases to be a class attribute.",
            thinker: "Karl Marx",
            source: "The Civil War in France (1871)"
        ),
        DailyQuote(
            text: "The political rule of the producer cannot co-exist with the perpetuation of his social slavery.",
            thinker: "Karl Marx",
            source: "The Civil War in France (1871)"
        ),

        // ===============================================================
        // MARK: - Karl Marx & Friedrich Engels — The Communist Manifesto
        // ===============================================================
        DailyQuote(
            text: "Workers of the world, unite! You have nothing to lose but your chains.",
            thinker: "Karl Marx & Friedrich Engels",
            source: "The Communist Manifesto (1848)"
        ),
        DailyQuote(
            text: "What the bourgeoisie produces, above all, are its own grave-diggers.",
            thinker: "Karl Marx & Friedrich Engels",
            source: "The Communist Manifesto (1848)"
        ),
        DailyQuote(
            text: "In proportion as the exploitation of one individual by another is put to an end, the exploitation of one nation by another will also be put to an end.",
            thinker: "Karl Marx & Friedrich Engels",
            source: "The Communist Manifesto (1848)"
        ),
        DailyQuote(
            text: "The bourgeoisie has stripped of its halo every occupation hitherto honoured and looked up to with reverent awe.",
            thinker: "Karl Marx & Friedrich Engels",
            source: "The Communist Manifesto (1848)"
        ),
        DailyQuote(
            text: "The bourgeoisie has converted the physician, the lawyer, the priest, the poet, the man of science, into its paid wage labourers.",
            thinker: "Karl Marx & Friedrich Engels",
            source: "The Communist Manifesto (1848)"
        ),
        DailyQuote(
            text: "In bourgeois society, living labour is but a means to increase accumulated labour.",
            thinker: "Karl Marx & Friedrich Engels",
            source: "The Communist Manifesto (1848)"
        ),
        DailyQuote(
            text: "In bourgeois society capital is independent and has individuality, while the living person is dependent and has no individuality.",
            thinker: "Karl Marx & Friedrich Engels",
            source: "The Communist Manifesto (1848)"
        ),
        DailyQuote(
            text: "The bourgeoisie cannot exist without constantly revolutionising the instruments of production.",
            thinker: "Karl Marx & Friedrich Engels",
            source: "The Communist Manifesto (1848)"
        ),
        DailyQuote(
            text: "The bourgeoisie, during its rule of scarce one hundred years, has created more massive and more colossal productive forces than have all preceding generations together.",
            thinker: "Karl Marx & Friedrich Engels",
            source: "The Communist Manifesto (1848)"
        ),

        // ===============================================================
        // MARK: - Karl Marx — Other works
        // ===============================================================
        DailyQuote(
            text: "From each according to his abilities, to each according to his needs.",
            thinker: "Karl Marx",
            source: "Critique of the Gotha Programme (1875)"
        ),
        DailyQuote(
            text: "Machines were the weapon employed by the capitalists to quell the revolt of specialized labor.",
            thinker: "Karl Marx",
            source: "The Poverty of Philosophy (1847)"
        ),
        DailyQuote(
            text: "In communist society, where nobody has one exclusive sphere of activity, society regulates the general production and makes it possible for me to do one thing today and another tomorrow.",
            thinker: "Karl Marx",
            source: "The German Ideology (1846)"
        ),
        DailyQuote(
            text: "The mode of production of material life conditions the general process of social, political and intellectual life.",
            thinker: "Karl Marx",
            source: "A Contribution to the Critique of Political Economy (1859)"
        ),
        DailyQuote(
            text: "Labour is the living, form-giving fire; it is the transitoriness of things, their temporality, as their formation by living time.",
            thinker: "Karl Marx",
            source: "Grundrisse (1858)"
        ),
        DailyQuote(
            text: "Instead of the conservative motto: A fair day's wage for a fair day's work! they ought to inscribe on their banner the revolutionary watchword: Abolition of the wages system!",
            thinker: "Karl Marx",
            source: "Value, Price and Profit (1865)"
        ),
        DailyQuote(
            text: "Labour is the worker's own life-activity, the manifestation of his own life. And this life-activity he sells to another person.",
            thinker: "Karl Marx",
            source: "Wage Labour and Capital (1849)"
        ),
        DailyQuote(
            text: "The rich will do anything for the poor but get off their backs.",
            thinker: "Karl Marx",
            source: nil
        ),

        // ===============================================================
        // MARK: - Friedrich Engels
        // ===============================================================
        DailyQuote(
            text: "Labour is the prime basic condition for all human existence, and this to such an extent that, in a sense, we have to say that labour created man himself.",
            thinker: "Friedrich Engels",
            source: "The Part Played by Labour in the Transition from Ape to Man (1876)"
        ),
        DailyQuote(
            text: "Labor is the source of all wealth, the political economists assert. And it really is the source — next to nature, which supplies it with the material that it converts into wealth.",
            thinker: "Friedrich Engels",
            source: "Dialectics of Nature (1883)"
        ),
        DailyQuote(
            text: "The slave frees himself when, of all the relations of private property, he abolishes only the relation of slavery and thereby becomes a proletarian; the proletarian can free himself only by abolishing private property in general.",
            thinker: "Friedrich Engels",
            source: "The Principles of Communism (1847)"
        ),
        DailyQuote(
            text: "The division of society into an exploiting and an exploited class, a ruling and an oppressed class, was the necessary consequence of the deficient and restricted development of production.",
            thinker: "Friedrich Engels",
            source: "Anti-Dühring (1878)"
        ),
        DailyQuote(
            text: "An ounce of action is worth a ton of theory.",
            thinker: "Friedrich Engels",
            source: nil
        ),
        DailyQuote(
            text: "The worker of today seems to be free because he is not sold once for all, but piecemeal by the day, the week, the year.",
            thinker: "Friedrich Engels",
            source: "The Condition of the Working Class in England (1845)"
        ),
        DailyQuote(
            text: "When society places workers under conditions in which they cannot live and permits these conditions to remain, its deed is murder just as surely as the deed of the single individual.",
            thinker: "Friedrich Engels",
            source: "The Condition of the Working Class in England (1845)"
        ),
        DailyQuote(
            text: "The perfecting of machinery is making human labor superfluous.",
            thinker: "Friedrich Engels",
            source: "Socialism: Utopian and Scientific (1880)"
        ),
        DailyQuote(
            text: "So long as the total social labor only yields a produce which but slightly exceeds that barely necessary for the existence of all, society is divided into classes.",
            thinker: "Friedrich Engels",
            source: "Socialism: Utopian and Scientific (1880)"
        ),
        DailyQuote(
            text: "The determining factor in history is, in the final instance, the production and reproduction of the immediate essentials of life.",
            thinker: "Friedrich Engels",
            source: "The Origin of the Family (1884)"
        ),
        DailyQuote(
            text: "The emancipation of woman will only be possible when woman can take part in production on a large, social scale, and domestic work no longer claims anything but an insignificant amount of her time.",
            thinker: "Friedrich Engels",
            source: "The Origin of the Family (1884)"
        ),

        // ===============================================================
        // MARK: - Vladimir Lenin
        // ===============================================================
        DailyQuote(
            text: "He who does not work shall not eat.",
            thinker: "Vladimir Lenin",
            source: "The State and Revolution (1917)"
        ),
        DailyQuote(
            text: "The productivity of labor is, in the last analysis, the most important, the principal thing for the victory of the new social system.",
            thinker: "Vladimir Lenin",
            source: "A Great Beginning (1919)"
        ),
        DailyQuote(
            text: "Subbotniks are of enormous historical significance precisely because they demonstrate the conscious and voluntary initiative of the workers in raising the productivity of labor.",
            thinker: "Vladimir Lenin",
            source: "A Great Beginning (1919)"
        ),
        DailyQuote(
            text: "In every socialist revolution, after the proletariat has solved the problem of capturing power, there comes to the forefront the fundamental task of creating a social system superior to capitalism, namely, raising the productivity of labour.",
            thinker: "Vladimir Lenin",
            source: "A Great Beginning (1919)"
        ),
        DailyQuote(
            text: "Social-Democracy leads the struggle of the working class not only for better terms for the sale of labour power, but also for the abolition of the social system which compels the propertyless to sell themselves to the rich.",
            thinker: "Vladimir Lenin",
            source: "What Is to Be Done? (1902)"
        ),
        DailyQuote(
            text: "Capital, created by the labour of the worker, crushes the worker, ruining small proprietors and creating an army of unemployed.",
            thinker: "Vladimir Lenin",
            source: "The Three Sources and Three Component Parts of Marxism (1913)"
        ),
        DailyQuote(
            text: "Keep regular and honest accounts of money, manage economically, do not be lazy, do not steal, observe the strictest labour discipline.",
            thinker: "Vladimir Lenin",
            source: "The Immediate Tasks of the Soviet Government (1918)"
        ),
        DailyQuote(
            text: "The task that the Soviet government must set the people in all its scope is — learn to work.",
            thinker: "Vladimir Lenin",
            source: "The Immediate Tasks of the Soviet Government (1918)"
        ),

        // ===============================================================
        // MARK: - Mao Zedong
        // ===============================================================
        DailyQuote(
            text: "The wealth of society is created by the workers, peasants, and working intellectuals.",
            thinker: "Mao Zedong",
            source: "Quotations (1964)"
        ),
        DailyQuote(
            text: "The people, and the people alone, are the motive force in the making of world history.",
            thinker: "Mao Zedong",
            source: "On Coalition Government (1945)"
        ),
        DailyQuote(
            text: "All our literature and art are for the masses of the people, and in the first place for the workers, peasants, and soldiers.",
            thinker: "Mao Zedong",
            source: "Talks at the Yenan Forum (1942)"
        ),
        DailyQuote(
            text: "What is work? Work is struggle. There are difficulties and problems in those places for us to overcome and solve. We go there to work and struggle to overcome these difficulties. A good comrade is one who is more eager to go where the difficulties are greater.",
            thinker: "Mao Zedong",
            source: "Quotations, Ch. 21 (1964)"
        ),
        DailyQuote(
            text: "The masses have boundless creative power. They can organize themselves and concentrate on places and branches of work where they can give full play to their energy.",
            thinker: "Mao Zedong",
            source: "Quotations, Ch. 11 (1964)"
        ),
        DailyQuote(
            text: "Class struggle, the struggle for production, and scientific experiment are the three great revolutionary movements for building a mighty socialist country.",
            thinker: "Mao Zedong",
            source: "Quotations (1964)"
        ),
        DailyQuote(
            text: "Marxists regard man's activity in production as the most fundamental practical activity, the determinant of all his other activities.",
            thinker: "Mao Zedong",
            source: "On Contradiction (1937)"
        ),
        DailyQuote(
            text: "We stand for self-reliance. We hope for foreign aid but cannot be dependent on it; we depend on our own efforts, on the creative power of the whole army and the entire people.",
            thinker: "Mao Zedong",
            source: "We Must Learn to Do Economic Work (1945)"
        ),
        DailyQuote(
            text: "The ruthless economic exploitation and political oppression of the peasants by the landlord class forced the peasants to rise repeatedly in revolt.",
            thinker: "Mao Zedong",
            source: "The Chinese Revolution and the Chinese Communist Party (1939)"
        ),

        // ===============================================================
        // MARK: - Hannah Arendt
        // ===============================================================
        DailyQuote(
            text: "Labor is the activity which corresponds to the biological process of the human body.",
            thinker: "Hannah Arendt",
            source: "The Human Condition (1958)"
        ),
        DailyQuote(
            text: "The modern age has carried with it a theoretical glorification of labor and has resulted in a factual transformation of the whole of society into a laboring society.",
            thinker: "Hannah Arendt",
            source: "The Human Condition (1958)"
        ),
        DailyQuote(
            text: "The distinction between labor and work is that labor leaves nothing behind, while work produces a durable world of things.",
            thinker: "Hannah Arendt",
            source: "The Human Condition (1958)"
        ),
        DailyQuote(
            text: "The spare time of the animal laborans is never spent in anything but consumption, and the more time left to him, the greedier and more craving his appetites.",
            thinker: "Hannah Arendt",
            source: "The Human Condition (1958)"
        ),
        DailyQuote(
            text: "It is a society of laborers which is about to be liberated from the fetters of labor, and this society does no longer know of those other higher and more meaningful activities for the sake of which this freedom would deserve to be won.",
            thinker: "Hannah Arendt",
            source: "The Human Condition (1958)"
        ),
        DailyQuote(
            text: "The last stage of a laboring society demands of its members a sheer automatic functioning.",
            thinker: "Hannah Arendt",
            source: "The Human Condition (1958)"
        ),
        DailyQuote(
            text: "What we are confronted with is the prospect of a society of laborers without labor, that is, without the only activity left to them.",
            thinker: "Hannah Arendt",
            source: "The Human Condition (1958)"
        ),
        DailyQuote(
            text: "It is indeed the mark of all laboring that it leaves nothing behind, that the result of its effort is almost as quickly consumed as the effort is spent.",
            thinker: "Hannah Arendt",
            source: "The Human Condition (1958)"
        ),
        DailyQuote(
            text: "The ideals of homo faber, the fabricator of the world, which are permanence, stability, and durability, have been sacrificed to abundance, the ideal of the animal laborans.",
            thinker: "Hannah Arendt",
            source: "The Human Condition (1958)"
        ),
        DailyQuote(
            text: "One of the obvious danger signs that we may be on our way to bring into existence the ideal of the animal laborans is the extent to which our whole economy has become a waste economy.",
            thinker: "Hannah Arendt",
            source: "The Human Condition (1958)"
        ),

        // ===============================================================
        // MARK: - Rosa Luxemburg
        // ===============================================================
        DailyQuote(
            text: "Those who do not move, do not notice their chains.",
            thinker: "Rosa Luxemburg",
            source: nil
        ),
        DailyQuote(
            text: "Our program becomes not the realization of Socialism, but the reform of capitalism; not the suppression of the system of wage labor, but the diminution of exploitation.",
            thinker: "Rosa Luxemburg",
            source: "Reform or Revolution (1899)"
        ),
        DailyQuote(
            text: "Bourgeois class domination is undoubtedly an historical necessity, but so too the rising of the working class against it. Capital is an historical necessity, but so too its grave digger, the socialist proletariat.",
            thinker: "Rosa Luxemburg",
            source: "Reform or Revolution (1899)"
        ),
        DailyQuote(
            text: "Capital ransacks the whole world, it procures its means of production from all corners of the earth, seizing them, if necessary by force, from all levels of civilisation and from all forms of society.",
            thinker: "Rosa Luxemburg",
            source: "The Accumulation of Capital (1913)"
        ),

        // ===============================================================
        // MARK: - Paul Lafargue
        // ===============================================================
        DailyQuote(
            text: "The proletariat has allowed itself to be degraded by the dogma of work.",
            thinker: "Paul Lafargue",
            source: "The Right to Be Lazy (1883)"
        ),
        DailyQuote(
            text: "A strange delusion possesses the working classes of the nations where capitalist civilization holds its sway. This delusion is the love of work, the furious passion for work, pushed even to the exhaustion of the vital force of the individual.",
            thinker: "Paul Lafargue",
            source: "The Right to Be Lazy (1883)"
        ),
        DailyQuote(
            text: "Work, work, proletarians, to increase social wealth and your individual poverty; work, work, in order that becoming poorer, you may have more reason to work and become miserable.",
            thinker: "Paul Lafargue",
            source: "The Right to Be Lazy (1883)"
        ),
        DailyQuote(
            text: "Our epoch has been called the century of work. It is in fact the century of pain, misery and corruption.",
            thinker: "Paul Lafargue",
            source: "The Right to Be Lazy (1883)"
        ),
        DailyQuote(
            text: "Confronted with this double madness of the labourers killing themselves with over-production and vegetating in abstinence, the great problem of capitalist production is no longer to find producers but to discover consumers.",
            thinker: "Paul Lafargue",
            source: "The Right to Be Lazy (1883)"
        ),
        DailyQuote(
            text: "In proportion as the machine is improved and performs man's work with an ever increasing rapidity and exactness, the labourer, instead of prolonging his former rest times, redoubles his ardour, as if he wished to rival the machine.",
            thinker: "Paul Lafargue",
            source: "The Right to Be Lazy (1883)"
        ),
        DailyQuote(
            text: "The Greeks in their era of greatness had only contempt for work: their slaves alone were permitted to labor; the free man knew only exercises for the body and mind.",
            thinker: "Paul Lafargue",
            source: "The Right to Be Lazy (1883)"
        ),
        DailyQuote(
            text: "The ancient philosophers had their disputes upon the origin of ideas but they agreed when it came to the abhorrence of work.",
            thinker: "Paul Lafargue",
            source: "The Right to Be Lazy (1883)"
        ),

        // ===============================================================
        // MARK: - Leon Trotsky
        // ===============================================================
        DailyQuote(
            text: "The old principle: who does not work shall not eat, has been replaced by a new one: who does not obey shall not eat.",
            thinker: "Leon Trotsky",
            source: "The Revolution Betrayed (1936)"
        ),
        DailyQuote(
            text: "Man strives to avoid labor. Love for work is not at all an inborn characteristic: it is created by economic pressure and social education.",
            thinker: "Leon Trotsky",
            source: "Terrorism and Communism (1920)"
        ),
        DailyQuote(
            text: "As long as human labor power, and consequently life itself, remain articles of sale and purchase, of exploitation and robbery, the principle of the sacredness of human life remains a shameful lie.",
            thinker: "Leon Trotsky",
            source: "Terrorism and Communism (1920)"
        ),
        DailyQuote(
            text: "The struggle to raise the productivity of labor, together with concern about defense, is the fundamental content of the activity of the Soviet government.",
            thinker: "Leon Trotsky",
            source: "The Revolution Betrayed (1936)"
        ),
        DailyQuote(
            text: "All economy comes down in the last analysis to an economy of time.",
            thinker: "Leon Trotsky",
            source: "The Revolution Betrayed (1936)"
        ),
        DailyQuote(
            text: "Quality demands a democracy of producers and consumers, freedom of criticism and initiative.",
            thinker: "Leon Trotsky",
            source: "The Revolution Betrayed (1936)"
        ),

        // ===============================================================
        // MARK: - Che Guevara
        // ===============================================================
        DailyQuote(
            text: "Volunteer work is a school for consciousness; it is an effort carried out in society and for society as a contribution.",
            thinker: "Che Guevara",
            source: "Man and Socialism in Cuba (1965)"
        ),
        DailyQuote(
            text: "Man truly reaches a full human condition when he produces without being driven by the physical need to sell his labor as a commodity.",
            thinker: "Che Guevara",
            source: "Man and Socialism in Cuba (1965)"
        ),
        DailyQuote(
            text: "Work must acquire a new condition; man as commodity ceases to exist and a system is established that grants a quota for the fulfillment of social duty.",
            thinker: "Che Guevara",
            source: "Man and Socialism in Cuba (1965)"
        ),

        // ===============================================================
        // MARK: - Bertolt Brecht
        // ===============================================================
        DailyQuote(
            text: "Who built Thebes of the seven gates? In the books you will find the names of kings. Did the kings haul up the lumps of rock?",
            thinker: "Bertolt Brecht",
            source: "Questions From a Worker Who Reads (1935)"
        ),
        DailyQuote(
            text: "Every page a victory. Who cooked the feast for the victors? Every ten years a great man. Who paid the bill? So many reports. So many questions.",
            thinker: "Bertolt Brecht",
            source: "Questions From a Worker Who Reads (1935)"
        ),
        DailyQuote(
            text: "When we come to you, our rags are torn off us and you listen all over our naked body. As to the cause of our illness, one glance at our rags would tell you more. It is the same cause that wears out our bodies and our clothes.",
            thinker: "Bertolt Brecht",
            source: "A Worker's Speech to a Doctor (1938)"
        ),

        // ===============================================================
        // MARK: - Frantz Fanon
        // ===============================================================
        DailyQuote(
            text: "The people come to understand that wealth is not the fruit of labour but the result of organised, protected robbery.",
            thinker: "Frantz Fanon",
            source: "The Wretched of the Earth (1961)"
        ),

        // ===============================================================
        // MARK: - Thomas Sankara
        // ===============================================================
        DailyQuote(
            text: "He who feeds you, controls you.",
            thinker: "Thomas Sankara",
            source: nil
        ),
        DailyQuote(
            text: "Let us consume what we produce and produce what we consume.",
            thinker: "Thomas Sankara",
            source: nil
        ),

        // ===============================================================
        // MARK: - Alexandra Kollontai
        // ===============================================================
        DailyQuote(
            text: "Capitalism has placed a crushing burden on woman's shoulders: it has made her a wage-worker without having reduced her cares as housekeeper or mother.",
            thinker: "Alexandra Kollontai",
            source: "Communism and the Family (1920)"
        ),
        DailyQuote(
            text: "Labor leads women on the straight road to her economic independence, but current capitalist relations make the conditions of labor unbearable.",
            thinker: "Alexandra Kollontai",
            source: "The Social Basis of the Woman Question (1909)"
        ),
    ]
}
